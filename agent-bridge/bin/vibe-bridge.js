#!/usr/bin/env node
"use strict";

/**
 * Vibe agent bridge daemon.
 *
 * Runs on the user's OWN computer. Pairs to a Vibe account with a one-time code,
 * then connects (outbound only) to the Vibe server and waits for `run_task`
 * events. For each task it runs `claude` / `codex` locally and streams the raw
 * output back — the Vibe server parses it and posts the result into the chat.
 *
 * Usage:
 *   npx @vibegram/agent-bridge --code <PAIRING_CODE> --server https://your-vibe-server
 *   # subsequent runs (token cached in ~/.vibe/bridge.json):
 *   npx @vibegram/agent-bridge --server https://your-vibe-server
 *
 * Safety: defaults to read-only execution (claude --permission-mode plan,
 * codex --sandbox read-only). Escalate explicitly via the env vars below.
 */

const fs = require("fs");
const os = require("os");
const path = require("path");
const crypto = require("crypto");
const { spawn } = require("child_process");

let WebSocket, Phoenix;
try {
  WebSocket = require("ws");
  Phoenix = require("phoenix");
} catch (err) {
  console.error(
    "[vibe-bridge] Missing dependencies. Run `npm install` in the agent-bridge folder (needs `ws` and `phoenix`)."
  );
  process.exit(1);
}

// ── Config / args ───────────────────────────────────────────────────

const CONFIG_DIR = path.join(os.homedir(), ".vibe");
const CONFIG_FILE = path.join(CONFIG_DIR, "bridge.json");
const MAX_PROGRESS_LINES = 60; // cap chatter per task
const MAX_LINE_BYTES = 8 * 1024;

function parseArgs(argv) {
  const out = { repos: [], repoRoots: [] };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--code") out.code = argv[++i];
    else if (a === "--server") out.server = argv[++i];
    else if (a === "--cwd") out.cwd = argv[++i];
    else if (a === "--repo") out.repos.push(argv[++i]);
    else if (a === "--repo-root") out.repoRoots.push(argv[++i]);
    else if (a === "--label") out.label = argv[++i];
    else if (a === "--logout") out.logout = true;
    else if (a === "-h" || a === "--help") out.help = true;
  }
  return out;
}

const ARGS = parseArgs(process.argv);

function loadConfig() {
  try {
    return JSON.parse(fs.readFileSync(CONFIG_FILE, "utf8"));
  } catch (_) {
    return {};
  }
}

function saveConfig(obj) {
  fs.mkdirSync(CONFIG_DIR, { recursive: true, mode: 0o700 });
  fs.writeFileSync(CONFIG_FILE, JSON.stringify(obj, null, 2), { mode: 0o600 });
}

function normalizeServer(url) {
  if (!url) return url;
  return url.replace(/\/+$/, "");
}

function splitEnvList(value) {
  return String(value || "")
    .split(/[,\n;]/)
    .map((part) => part.trim())
    .filter(Boolean);
}

function expandHome(value) {
  const raw = String(value || "").trim();
  if (!raw) return null;
  if (raw === "~") return os.homedir();
  if (raw.startsWith("~/")) return path.join(os.homedir(), raw.slice(2));
  return raw;
}

function realDir(value) {
  const expanded = expandHome(value);
  if (!expanded) return null;
  try {
    const resolved = fs.realpathSync(path.resolve(expanded));
    if (fs.statSync(resolved).isDirectory()) return resolved;
  } catch (_) {}
  return null;
}

function findGitRoot(dir) {
  let current = realDir(dir);
  while (current) {
    if (fs.existsSync(path.join(current, ".git"))) return current;
    const parent = path.dirname(current);
    if (!parent || parent === current) break;
    current = parent;
  }
  return realDir(dir);
}

function repoIdFor(cwd) {
  return crypto.createHash("sha256").update(cwd).digest("base64url").slice(0, 16);
}

function repoNameFor(cwd) {
  if (cwd === os.homedir()) return "~";
  return path.basename(cwd) || cwd;
}

function addRepository(map, dir, source) {
  const root = findGitRoot(dir);
  if (!root || map.has(root)) return;
  map.set(root, {
    id: repoIdFor(root),
    name: repoNameFor(root),
    path: root,
    cwd: root,
    source,
    git: fs.existsSync(path.join(root, ".git")),
  });
}

function scanRepoRoot(root, map) {
  const start = realDir(root);
  if (!start) return;
  const queue = [{ dir: start, depth: 0 }];
  const seen = new Set();
  while (queue.length && map.size < 80) {
    const { dir, depth } = queue.shift();
    if (seen.has(dir)) continue;
    seen.add(dir);
    if (fs.existsSync(path.join(dir, ".git"))) {
      addRepository(map, dir, "repo-root");
      continue;
    }
    if (depth >= 2) continue;
    let entries = [];
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch (_) {
      continue;
    }
    for (const entry of entries) {
      if (!entry.isDirectory() || entry.name.startsWith(".")) continue;
      queue.push({ dir: path.join(dir, entry.name), depth: depth + 1 });
    }
  }
}

function buildRepositories() {
  const map = new Map();
  const defaultCwd = realDir(ARGS.cwd || process.cwd()) || process.cwd();
  addRepository(map, defaultCwd, "cwd");

  for (const repo of [
    ...ARGS.repos,
    ...splitEnvList(process.env.VIBE_BRIDGE_REPOS),
  ]) {
    addRepository(map, repo, "explicit");
  }

  for (const root of [
    ...ARGS.repoRoots,
    ...splitEnvList(process.env.VIBE_BRIDGE_REPO_ROOTS),
  ]) {
    scanRepoRoot(root, map);
  }

  return Array.from(map.values()).sort((a, b) => a.name.localeCompare(b.name));
}

// ── Pairing ─────────────────────────────────────────────────────────

async function redeemPairing(server, code, label) {
  const res = await fetch(`${server}/api/agent-bridge/pair`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ pairing_code: code, device_label: label || os.hostname() }),
  });
  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new Error(`pairing failed (${res.status}): ${body}`);
  }
  return res.json(); // { bridge_token, user_id }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function startPairRequest(server, label) {
  const res = await fetch(`${server}/api/agent-bridge/request`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ device_label: label || os.hostname() }),
  });
  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new Error(`could not start pairing (${res.status}): ${body}`);
  }
  return res.json(); // { request_id, device_secret, expires_in }
}

async function claimPairToken(server, requestId, deviceSecret) {
  const res = await fetch(`${server}/api/agent-bridge/claim`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ request_id: requestId, device_secret: deviceSecret }),
  });
  if (res.status === 202) return null; // still pending — phone hasn't scanned yet
  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new Error(`claim failed (${res.status}): ${body}`);
  }
  return res.json(); // { bridge_token, user_id }
}

function renderQR(payload) {
  try {
    require("qrcode-terminal").generate(payload, { small: true });
  } catch (_) {
    console.log("(Tip: `npm i qrcode-terminal` in this folder for a scannable QR.)");
  }
  console.log(`\n  manual code: ${payload}\n`);
}

// Desktop-shows-QR / phone-scans pairing (WhatsApp-Web style). The daemon holds
// a private device_secret; the QR only carries the public request_id, so anyone
// who merely sees the QR cannot claim the token.
async function scanToPair(server, label) {
  const { request_id, device_secret, expires_in } = await startPairRequest(server, label);
  console.log(
    "\n[vibe-bridge] In Vibe on your phone: open Claude or Codex → Connect → Scan, then scan this:\n"
  );
  renderQR(`vibegram-pair:${request_id}`);
  console.log(`[vibe-bridge] Waiting for your phone to authorize (expires in ${expires_in}s)…`);

  const deadline = Date.now() + expires_in * 1000;
  while (Date.now() < deadline) {
    await sleep(2500);
    const result = await claimPairToken(server, request_id, device_secret);
    if (result && result.bridge_token) {
      process.stdout.write("\n[vibe-bridge] Auth is done — waiting for your computer...\n");
      return result;
    }
    process.stdout.write(".");
  }
  throw new Error("pairing timed out — re-run to get a fresh code");
}

// ── Running claude / codex ──────────────────────────────────────────

const sessionByChat = new Map(); // chatId -> claude session_id

function stripReservedMention(prompt, provider) {
  return String(prompt || "")
    .replace(/(^|\s)@(codex|claude)\b/ig, " ")
    .trim();
}

// Normalise the per-task permission level chosen on the phone into one of four
// modes. Accepts a range of aliases so older clients / env overrides keep working.
//   ask         — live per-action approval (safe-propose until the live channel
//                 lands; see VIBE live-approval follow-up)
//   read_only   — analyse & propose, never change files
//   allow_edits — auto-approve edits + sandboxed command execution
//   full_access — no sandbox, run anything
function workModeFor(task) {
  const raw = String(
    (task && (task.workMode || task.agentBridgeWorkMode || task.mode)) || "read_only"
  )
    .trim()
    .toLowerCase();
  if (
    ["full_access", "full", "danger", "danger-full-access", "bypass", "bypasspermissions"].includes(
      raw
    )
  ) {
    return "full_access";
  }
  if (
    ["allow_edits", "auto", "edit", "edits", "write", "workspace-write", "accept_edits"].includes(
      raw
    )
  ) {
    return "allow_edits";
  }
  if (["ask", "approve", "live", "prompt"].includes(raw)) {
    return "ask";
  }
  return "read_only";
}

function claudePermissionMode(task) {
  if (process.env.VIBE_CLAUDE_PERMISSION_MODE) return process.env.VIBE_CLAUDE_PERMISSION_MODE;
  switch (workModeFor(task)) {
    case "full_access":
      return "bypassPermissions";
    case "allow_edits":
      return "acceptEdits";
    // "ask" maps to plan for now (propose, don't execute) until live mobile
    // approval is wired; "read_only" is plan too.
    default:
      return "plan";
  }
}

function codexSandbox(task) {
  if (process.env.VIBE_CODEX_SANDBOX) return process.env.VIBE_CODEX_SANDBOX;
  switch (workModeFor(task)) {
    case "full_access":
      return "danger-full-access";
    case "allow_edits":
      return "workspace-write";
    default:
      return "read-only";
  }
}

function buildCommand(provider, prompt, chatId, task) {
  const cleaned = stripReservedMention(prompt, provider);
  if (provider === "claude") {
    const mode = claudePermissionMode(task);
    const args = ["-p", "--output-format", "stream-json", "--permission-mode", mode];
    const sid = sessionByChat.get(chatId);
    if (sid) args.push("--resume", sid);
    args.push("--verbose");
    if (process.env.VIBE_CLAUDE_MODEL) args.push("--model", process.env.VIBE_CLAUDE_MODEL);
    args.push("--", cleaned);
    return { cmd: process.env.VIBE_CLAUDE_COMMAND || "claude", args };
  }
  if (provider === "codex") {
    const sandbox = codexSandbox(task);
    const args = [
      "exec",
      "--json",
      "--sandbox",
      sandbox,
      "--skip-git-repo-check",
      "--ephemeral",
    ];
    if (process.env.VIBE_CODEX_MODEL) args.push("--model", process.env.VIBE_CODEX_MODEL);
    args.push(cleaned);
    return { cmd: process.env.VIBE_CODEX_COMMAND || "codex", args };
  }
  return null;
}

const ADVERTISED_REPOSITORIES = buildRepositories();
const DEFAULT_CWD = realDir(ARGS.cwd || process.cwd()) || process.cwd();

function repositoryById(id) {
  if (!id) return null;
  return ADVERTISED_REPOSITORIES.find((repo) => repo.id === id) || null;
}

function repositoryByPath(value) {
  const real = realDir(value);
  if (!real) return null;
  return ADVERTISED_REPOSITORIES.find((repo) => repo.cwd === real || repo.path === real) || null;
}

function defaultRepository() {
  return (
    repositoryByPath(DEFAULT_CWD) ||
    ADVERTISED_REPOSITORIES[0] || {
      id: repoIdFor(DEFAULT_CWD),
      name: repoNameFor(DEFAULT_CWD),
      path: DEFAULT_CWD,
      cwd: DEFAULT_CWD,
      source: "cwd",
      git: fs.existsSync(path.join(DEFAULT_CWD, ".git")),
    }
  );
}

function resolveTaskRepository(task) {
  const requestedId = task.repoId || task.repositoryId || task.agentBridgeRepoId;
  const requestedPath =
    task.cwd || task.repoPath || task.repositoryPath || task.agentBridgeCwd || task.agentBridgeRepoPath;

  if (requestedId) {
    const repo = repositoryById(String(requestedId));
    if (repo) return { ok: true, repo };
    return { ok: false, reason: "unknown repository id" };
  }

  if (requestedPath) {
    const repo = repositoryByPath(String(requestedPath));
    if (repo) return { ok: true, repo };
    return { ok: false, reason: "repository path is not allowed" };
  }

  return { ok: true, repo: defaultRepository() };
}

function bridgeStatusPayload() {
  return {
    deviceLabel: ARGS.label || os.hostname(),
    cwd: DEFAULT_CWD,
    repositories: ADVERTISED_REPOSITORIES,
    permissions: {
      claude: {
        permissionMode: process.env.VIBE_CLAUDE_PERMISSION_MODE || "per-task",
        command: process.env.VIBE_CLAUDE_COMMAND || "claude",
      },
      codex: {
        sandbox: process.env.VIBE_CODEX_SANDBOX || "per-task",
        command: process.env.VIBE_CODEX_COMMAND || "codex",
      },
      workModes: ["ask", "read_only", "allow_edits", "full_access"],
    },
  };
}

function pushBridgeStatus(channel) {
  if (channel.state === "joined") {
    channel.push("status", bridgeStatusPayload());
  }
}

function captureSessionId(line) {
  try {
    const ev = JSON.parse(line);
    if (ev && typeof ev.session_id === "string") return ev.session_id;
  } catch (_) {}
  return null;
}

function looksToolish(line) {
  // Cheap filter so we only forward lines that may carry tool activity.
  return (
    line.includes("tool_use") ||
    line.includes("tool_result") ||
    line.includes('"command"') ||
    line.includes("function_call") ||
    line.includes('"tool"')
  );
}

function runTask(channel, task) {
  const { provider, chatId, prompt, replyToId, requesterUserId } = task;
  const built = buildCommand(provider, prompt, chatId, task);
  if (!built) {
    channel.push("error", { provider, chatId, message: `Unknown provider: ${provider}` });
    return;
  }

  const repoResult = resolveTaskRepository(task || {});
  if (!repoResult.ok) {
    channel.push("error", {
      provider,
      chatId,
      message: `Refused to run ${provider}: ${repoResult.reason}. Add it with --repo or VIBE_BRIDGE_REPOS on your computer.`,
      replyToId,
    });
    return;
  }

  const repo = repoResult.repo;
  const cwd = repo.cwd || repo.path || DEFAULT_CWD;
  console.log(`[vibe-bridge] run ${provider} chat=${chatId} cwd=${cwd}`);

  const startedAt = Date.now();
  let child;
  try {
    child = spawn(built.cmd, built.args, { cwd, stdio: ["ignore", "pipe", "pipe"] });
  } catch (err) {
    channel.push("error", { provider, chatId, message: `Could not start ${built.cmd}: ${err.message}`, replyToId });
    return;
  }

  let output = "";
  let lineBuf = "";
  let progressCount = 0;

  const onChunk = (buf) => {
    const text = buf.toString();
    output += text;
    lineBuf += text;
    let idx;
    while ((idx = lineBuf.indexOf("\n")) >= 0) {
      const line = lineBuf.slice(0, idx).replace(/\r$/, "");
      lineBuf = lineBuf.slice(idx + 1);
      if (!line) continue;
      const sid = captureSessionId(line);
      if (sid) sessionByChat.set(chatId, sid);
      if (progressCount < MAX_PROGRESS_LINES && line.length <= MAX_LINE_BYTES && looksToolish(line)) {
        progressCount++;
        channel.push("progress", { provider, chatId, line });
      }
    }
  };

  child.stdout.on("data", onChunk);
  child.stderr.on("data", onChunk);

  child.on("error", (err) => {
    channel.push("error", { provider, chatId, message: `${built.cmd} failed: ${err.message}`, replyToId });
  });

  child.on("close", (code) => {
    const durationMs = Date.now() - startedAt;
    console.log(`[vibe-bridge] done ${provider} chat=${chatId} exit=${code} ${durationMs}ms`);
    channel.push("result", {
      provider,
      chatId,
      output,
      exitStatus: code == null ? 1 : code,
      durationMs,
      replyToId,
      requesterUserId,
      repoId: repo.id,
      cwd,
      workMode: workModeFor(task),
    });
  });
}

// ── Socket / channel ────────────────────────────────────────────────

function wsUrl(server) {
  return server.replace(/^http/, "ws") + "/agent-bridge";
}

function connect(server, token, userId) {
  const socket = new Phoenix.Socket(wsUrl(server), {
    params: { token },
    transport: WebSocket,
    reconnectAfterMs: (tries) => [1000, 2000, 5000, 10000][tries - 1] || 10000,
  });

  socket.onError(() => console.error("[vibe-bridge] socket error (will retry)"));
  socket.onClose(() => console.log("[vibe-bridge] socket closed (will retry)"));
  socket.connect();

  const channel = socket.channel(`bridge:${userId}`, {});
  channel.on("run_task", (task) => runTask(channel, task));

  channel
    .join()
    .receive("ok", () => {
      console.log(`\n✅ [vibe-bridge] CONNECTED! Your computer is now online for user ${userId}.\n   Leave this terminal open to run local AI tasks.\n`);
      if (ADVERTISED_REPOSITORIES.length) {
        console.log("[vibe-bridge] available repositories:");
        for (const repo of ADVERTISED_REPOSITORIES) {
          console.log(`   • ${repo.name}  ${repo.path}`);
        }
      }
      pushBridgeStatus(channel);
    })
    .receive("error", (e) => console.error("[vibe-bridge] join error:", JSON.stringify(e)));

  // Lightweight heartbeat to keep last_seen fresh (socket also heartbeats).
  setInterval(() => {
    if (channel.state === "joined") {
      channel.push("heartbeat", {});
      pushBridgeStatus(channel);
    }
  }, 30000);
}

// ── Main ────────────────────────────────────────────────────────────

async function main() {
  if (ARGS.help) {
    console.log(
      "Usage: vibegram-bridge --server <https://vibe-server>\n" +
        "         shows a QR — scan it in the Vibe app (Claude/Codex → Connect → Scan)\n" +
        "       vibegram-bridge --code <PAIRING_CODE> --server <...>   (manual code flow)\n" +
        "       vibegram-bridge --server <...>   (reuses cached token)\n" +
        "       vibegram-bridge --server <...> --repo ~/Project --repo-root ~/Desktop\n" +
        "       vibegram-bridge --logout\n\n" +
        "Repo selection: --cwd sets the default working tree, --repo advertises an allowed repo,\n" +
        "     --repo-root scans two levels deep for .git directories. Env alternatives:\n" +
        "     VIBE_BRIDGE_REPOS, VIBE_BRIDGE_REPO_ROOTS.\n\n" +
        "Env: VIBE_CLAUDE_PERMISSION_MODE and VIBE_CODEX_SANDBOX override the phone's mode,\n" +
        "     VIBE_CLAUDE_MODEL, VIBE_CODEX_MODEL, VIBE_CLAUDE_COMMAND, VIBE_CODEX_COMMAND"
    );
    return;
  }

  if (ARGS.logout) {
    try {
      fs.unlinkSync(CONFIG_FILE);
    } catch (_) {}
    console.log("[vibe-bridge] logged out (local token removed).");
    return;
  }

  const config = loadConfig();
  const server = normalizeServer(ARGS.server || config.server || "https://api.vibegram.io");
  if (!server) {
    console.error("[vibe-bridge] Missing --server <https://your-vibe-server>");
    process.exit(1);
  }

  let token = config.bridge_token;
  let userId = config.user_id;

  if (ARGS.code) {
    console.log("[vibe-bridge] pairing…");
    const result = await redeemPairing(server, ARGS.code, ARGS.label);
    token = result.bridge_token;
    userId = result.user_id;
    saveConfig({ server, bridge_token: token, user_id: userId });
    console.log("[vibe-bridge] paired ✓ (token cached in ~/.vibe/bridge.json)");
  }

  if (!token || !userId) {
    const result = await scanToPair(server, ARGS.label);
    token = result.bridge_token;
    userId = result.user_id;
    saveConfig({ server, bridge_token: token, user_id: userId });
    console.log("[vibe-bridge] paired ✓ (token cached in ~/.vibe/bridge.json)");
  }

  // Persist latest server if changed.
  if (config.server !== server) saveConfig({ server, bridge_token: token, user_id: userId });

  connect(server, token, userId);
}

main().catch((err) => {
  console.error("[vibe-bridge] fatal:", err.message);
  process.exit(1);
});
