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
const readline = require("readline");
const { spawn, execFileSync } = require("child_process");

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
    else if (a === "--pick") out.pick = true;
    else if (a === "--no-pick") out.noPick = true;
    else if (a === "--all") out.all = true;
    else if (a === "--install" || a === "--service") out.install = true;
    else if (a === "--uninstall") out.uninstall = true;
    else if (a === "--status") out.status = true;
    else if (a === "--service-run") out.serviceRun = true;
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

// Top-level folders that are never code projects — skip them so a scan of the
// home folder reaches real repos instead of filling up on system junk.
const SKIP_DIRS = new Set([
  "Library",
  "Applications",
  "Music",
  "Movies",
  "Pictures",
  "Downloads",
  "Public",
  "node_modules",
  ".Trash",
]);

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
      if (SKIP_DIRS.has(entry.name)) continue;
      queue.push({ dir: path.join(dir, entry.name), depth: depth + 1 });
    }
  }
}

// Common places people keep code — scanned (depth-limited) when the user runs an
// interactive pick and hasn't named repos explicitly.
function defaultDiscoveryRoots() {
  const home = os.homedir();
  return [
    process.cwd(),
    path.join(home, "Desktop"),
    path.join(home, "Developer"),
    path.join(home, "Projects"),
    path.join(home, "projects"),
    path.join(home, "Code"),
    path.join(home, "code"),
    path.join(home, "src"),
    path.join(home, "git"),
    path.join(home, "repos"),
    home,
  ].filter((dir) => realDir(dir));
}

function buildRepositories(extraRepos = []) {
  const map = new Map();

  // Repos the user picked interactively (or had cached) come first so they are
  // always advertised even if the daemon is launched from elsewhere.
  for (const repo of extraRepos) {
    addRepository(map, repo, "picked");
  }

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

  // The current working tree is a sensible fallback only when nothing else was
  // chosen — otherwise we'd silently re-add e.g. the folder the daemon ran from.
  if (map.size === 0) {
    const defaultCwd = realDir(ARGS.cwd || process.cwd()) || process.cwd();
    addRepository(map, defaultCwd, "cwd");
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

// Assigned in main() once repos are resolved (possibly via an interactive pick).
let ADVERTISED_REPOSITORIES = [];
let DEFAULT_CWD = realDir(ARGS.cwd || process.cwd()) || process.cwd();

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

// ── Interactive repo pick ───────────────────────────────────────────

function promptLine(question) {
  return new Promise((resolve) => {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    rl.question(question, (answer) => {
      rl.close();
      resolve(answer);
    });
  });
}

function discoverRepositories() {
  const map = new Map();
  for (const root of defaultDiscoveryRoots()) scanRepoRoot(root, map);
  addRepository(map, process.cwd(), "cwd");
  return Array.from(map.values()).sort((a, b) => a.name.localeCompare(b.name));
}

// Ask which project(s) @claude / @codex should work on. Returns an array of
// absolute paths (the user's choice), or null if they cancelled. Only called
// when stdin is a TTY.
async function pickRepositoriesInteractively() {
  const found = discoverRepositories();
  if (!found.length) {
    console.log("\n[vibe-bridge] No git repositories found near your home folder.");
    const custom = (
      await promptLine("  Enter a project path to link (blank = current folder): ")
    ).trim();
    return [custom || process.cwd()];
  }

  console.log("\n[vibe-bridge] Which project(s) should @claude / @codex work on?\n");
  found.forEach((r, i) => {
    console.log(`  ${String(i + 1).padStart(2)}. ${r.name}   ${r.path}`);
  });
  console.log("\n  Enter numbers (e.g. 1,3), 'all', or a path. Blank = the first one.");
  const answer = (await promptLine("  > ")).trim();

  if (!answer) return [found[0].path];
  if (answer.toLowerCase() === "all") return found.map((r) => r.path);
  if (answer.startsWith("~") || answer.startsWith("/") || answer.startsWith(".")) {
    return [answer];
  }
  const picks = answer
    .split(/[,\s]+/)
    .map((s) => parseInt(s, 10))
    .filter((n) => Number.isInteger(n) && n >= 1 && n <= found.length);
  if (!picks.length) return [found[0].path];
  return picks.map((n) => found[n - 1].path);
}

// Resolve which repos to advertise. Honors explicit flags/env first; otherwise
// reuses the cached pick, and prompts interactively the first time (or on
// `--pick`). Persists the chosen paths so later launches (incl. the background
// service) reuse them without asking.
async function resolveRepositories(config, persist) {
  const explicit =
    ARGS.repos.length ||
    ARGS.repoRoots.length ||
    ARGS.cwd ||
    splitEnvList(process.env.VIBE_BRIDGE_REPOS).length ||
    splitEnvList(process.env.VIBE_BRIDGE_REPO_ROOTS).length;

  let picked = Array.isArray(config.repos) ? config.repos.slice() : [];

  const interactive = process.stdin.isTTY && !ARGS.serviceRun && !ARGS.noPick;
  const shouldPrompt = interactive && (ARGS.pick || (!explicit && picked.length === 0));

  if (shouldPrompt) {
    if (ARGS.all) {
      picked = discoverRepositories().map((r) => r.path);
    } else {
      const chosen = await pickRepositoriesInteractively();
      if (chosen && chosen.length) picked = chosen;
    }
    config.repos = picked;
    if (persist) persist();
  }

  ADVERTISED_REPOSITORIES = buildRepositories(picked);
  DEFAULT_CWD =
    (ADVERTISED_REPOSITORIES[0] && ADVERTISED_REPOSITORIES[0].cwd) ||
    realDir(ARGS.cwd || process.cwd()) ||
    process.cwd();
}

// ── Background service (macOS launchd) ──────────────────────────────

const SERVICE_LABEL = "io.vibegram.agent-bridge";
const SERVICE_LOG = path.join(CONFIG_DIR, "bridge.log");

function servicePlistPath() {
  return path.join(os.homedir(), "Library", "LaunchAgents", `${SERVICE_LABEL}.plist`);
}

function escapeXml(value) {
  return String(value).replace(/[<>&'"]/g, (c) => {
    return { "<": "&lt;", ">": "&gt;", "&": "&amp;", "'": "&apos;", '"': "&quot;" }[c];
  });
}

function installService(server, config) {
  if (process.platform !== "darwin") {
    console.log(
      "[vibe-bridge] --install supports macOS (launchd) right now.\n" +
        "  On Linux, run as a user systemd unit or `nohup vibegram-bridge --server " +
        server +
        " >> ~/.vibe/bridge.log 2>&1 &`."
    );
    return;
  }
  if (!config.bridge_token || !config.user_id) {
    console.log(
      "[vibe-bridge] Pair first, then install the background service:\n" +
        "  1) vibegram-bridge --server " +
        server +
        "   (scan the QR in the app)\n" +
        "  2) vibegram-bridge --install"
    );
    return;
  }

  fs.mkdirSync(path.dirname(servicePlistPath()), { recursive: true });
  fs.mkdirSync(CONFIG_DIR, { recursive: true, mode: 0o700 });

  const args = [process.execPath, __filename, "--server", server, "--service-run"];
  const xml =
    '<?xml version="1.0" encoding="UTF-8"?>\n' +
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n' +
    '<plist version="1.0">\n' +
    "<dict>\n" +
    `  <key>Label</key><string>${SERVICE_LABEL}</string>\n` +
    "  <key>ProgramArguments</key>\n  <array>\n" +
    args.map((a) => `    <string>${escapeXml(a)}</string>`).join("\n") +
    "\n  </array>\n" +
    "  <key>RunAtLoad</key><true/>\n" +
    "  <key>KeepAlive</key><true/>\n" +
    "  <key>ThrottleInterval</key><integer>10</integer>\n" +
    `  <key>StandardOutPath</key><string>${escapeXml(SERVICE_LOG)}</string>\n` +
    `  <key>StandardErrorPath</key><string>${escapeXml(SERVICE_LOG)}</string>\n` +
    `  <key>WorkingDirectory</key><string>${escapeXml(os.homedir())}</string>\n` +
    "  <key>EnvironmentVariables</key>\n  <dict>\n" +
    `    <key>PATH</key><string>${escapeXml(
      process.env.PATH || "/usr/local/bin:/usr/bin:/bin"
    )}</string>\n` +
    "  </dict>\n" +
    "</dict>\n</plist>\n";

  fs.writeFileSync(servicePlistPath(), xml);
  try {
    execFileSync("launchctl", ["unload", servicePlistPath()], { stdio: "ignore" });
  } catch (_) {}
  execFileSync("launchctl", ["load", servicePlistPath()]);

  console.log(
    "\n✅ [vibe-bridge] Background service installed.\n" +
      "  • Runs at login and reconnects automatically — no terminal needed.\n" +
      "  • Restarts itself if it crashes.\n" +
      `  • Logs: ${SERVICE_LOG}\n` +
      "  • Stop & remove: vibegram-bridge --uninstall\n"
  );
}

function uninstallService() {
  if (process.platform !== "darwin") {
    console.log("[vibe-bridge] Nothing to uninstall (launchd is macOS-only).");
    return;
  }
  try {
    execFileSync("launchctl", ["unload", servicePlistPath()], { stdio: "ignore" });
  } catch (_) {}
  try {
    fs.unlinkSync(servicePlistPath());
  } catch (_) {}
  console.log("[vibe-bridge] Background service stopped and removed.");
}

function serviceStatus() {
  if (process.platform !== "darwin") {
    console.log("[vibe-bridge] Service status is macOS-only.");
    return;
  }
  const installed = fs.existsSync(servicePlistPath());
  console.log(`[vibe-bridge] background service: ${installed ? "installed" : "not installed"}`);
  if (installed) {
    try {
      const out = execFileSync("launchctl", ["list"], { encoding: "utf8" });
      const line = out.split("\n").find((l) => l.includes(SERVICE_LABEL));
      console.log(`  launchctl: ${line ? line.trim() : "loaded? (re-run with sudo if unsure)"}`);
    } catch (_) {}
    console.log(`  logs: ${SERVICE_LOG}`);
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
  console.log(
    `[vibe-bridge] run_task received provider=${provider} chat=${chatId} ` +
      `repoId=${task.repoId || task.agentBridgeRepoId || "-"} ` +
      `workMode=${task.workMode || task.agentBridgeWorkMode || "-"} promptLen=${(prompt || "").length}`
  );
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
      console.log(`\n✅ [vibe-bridge] CONNECTED! Your computer is now online for user ${userId}.`);
      if (ADVERTISED_REPOSITORIES.length) {
        console.log("[vibe-bridge] linked repositories:");
        for (const repo of ADVERTISED_REPOSITORIES) {
          console.log(`   • ${repo.name}  ${repo.path}`);
        }
      }
      if (!ARGS.serviceRun) {
        console.log(
          "\n   Leave this terminal open, OR run it in the background so you can close it:\n" +
            "     vibegram-bridge --install     (starts at login, auto-reconnects)\n" +
            "   Change projects later with:  vibegram-bridge --pick\n"
        );
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
      "Usage:\n" +
        "  vibegram-bridge --server <https://vibe-server>\n" +
        "      First run: shows a QR — scan it in the Vibe app (Claude/Codex → Connect → Scan),\n" +
        "      then asks which project(s) to link. Later runs reuse the cached token + pick.\n\n" +
        "  vibegram-bridge --pick            re-choose which project(s) to link\n" +
        "  vibegram-bridge --all             link every git repo found near your home folder\n" +
        "  vibegram-bridge --install         run in the background (starts at login, auto-reconnect)\n" +
        "  vibegram-bridge --uninstall       stop & remove the background service\n" +
        "  vibegram-bridge --status          show background-service state + log path\n" +
        "  vibegram-bridge --code <CODE>     manual pairing code flow\n" +
        "  vibegram-bridge --logout          remove the cached token\n\n" +
        "Non-interactive repo selection: --cwd <dir>, --repo <dir> (repeatable),\n" +
        "     --repo-root <dir> (scans 2 levels for .git). Env: VIBE_BRIDGE_REPOS,\n" +
        "     VIBE_BRIDGE_REPO_ROOTS, VIBE_CLAUDE_PERMISSION_MODE, VIBE_CODEX_SANDBOX,\n" +
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
  const persist = () => saveConfig(config);
  const server = normalizeServer(ARGS.server || config.server || "https://api.vibegram.io");
  if (!server) {
    console.error("[vibe-bridge] Missing --server <https://your-vibe-server>");
    process.exit(1);
  }
  config.server = server;

  // Background-service management (no socket needed).
  if (ARGS.uninstall) return uninstallService();
  if (ARGS.status) return serviceStatus();
  if (ARGS.install) return installService(server, config);

  if (ARGS.code) {
    console.log("[vibe-bridge] pairing…");
    const result = await redeemPairing(server, ARGS.code, ARGS.label);
    config.bridge_token = result.bridge_token;
    config.user_id = result.user_id;
    persist();
    console.log("[vibe-bridge] paired ✓ (token cached in ~/.vibe/bridge.json)");
  }

  if (!config.bridge_token || !config.user_id) {
    const result = await scanToPair(server, ARGS.label);
    config.bridge_token = result.bridge_token;
    config.user_id = result.user_id;
    persist();
    console.log("[vibe-bridge] paired ✓ (token cached in ~/.vibe/bridge.json)");
  }

  persist();

  // Resolve which project(s) to expose (interactive first run, cached after).
  await resolveRepositories(config, persist);

  connect(server, config.bridge_token, config.user_id);
}

main().catch((err) => {
  console.error("[vibe-bridge] fatal:", err.message);
  process.exit(1);
});
