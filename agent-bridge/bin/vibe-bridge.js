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
const MAX_PROGRESS_LINES = 400; // safety cap on streamed events per task
const MAX_LINE_BYTES = 8 * 1024;
const MAX_DIFF_BYTES = 90 * 1024;
const MAX_DIFF_FILES = 24;
const MAX_UNTRACKED_FILE_BYTES = 220 * 1024;

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
    else if (a === "--foreground") out.foreground = true;
    else if (a === "--self-test") out.selfTest = true;
    else if (a === "--self-test-revert") out.selfTestRevert = true;
    else if (a === "--self-test-sequence") out.selfTestSequence = true;
    else if (a === "--provider") out.provider = argv[++i];
    else if (a === "--prompt") out.prompt = argv[++i];
    else if (a === "--rk") out.rk = argv[++i];
    else if (a === "--show-key") out.showKey = true;
    else if (a === "--work-mode") out.workMode = argv[++i];
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

// ── End-to-end runtime encryption (zero-knowledge server) ────────────
// The runtime payload (diffs, patches, file paths, command output) is the
// user's real source code. The Vibe server must never be able to read it. The
// bridge encrypts it with a 32-byte key (AES-256-GCM) shared ONLY with the
// phone, over the pairing QR — a phone↔desktop visual channel the server never
// sees. The server stores/relays the opaque ciphertext and cannot decrypt it.
// Matches the iOS reader: "arte1.<ivB64url>.<ctB64url>.<tagB64url>".
let RUNTIME_KEY_B64 = null;
const RUNTIME_BLOB_PREFIX = "arte1";

function isValidRuntimeKeyB64(b64) {
  try {
    return Buffer.from(String(b64 || ""), "base64").length === 32;
  } catch (_) {
    return false;
  }
}

// Establish the per-pairing runtime key. Priority: explicit --rk handed over by
// the phone's pairing QR, then the cached key, otherwise generate a fresh one.
function ensureRuntimeKey(config) {
  if (ARGS.rk && isValidRuntimeKeyB64(ARGS.rk)) {
    config.runtime_key = Buffer.from(ARGS.rk, "base64").toString("base64");
  }
  if (!isValidRuntimeKeyB64(config.runtime_key)) {
    config.runtime_key = crypto.randomBytes(32).toString("base64");
  }
  RUNTIME_KEY_B64 = config.runtime_key;
  return RUNTIME_KEY_B64;
}

function runtimeKeyQRPayload() {
  return `vibegram-rk:${RUNTIME_KEY_B64}`;
}

function encryptRuntimeBlob(obj) {
  if (!RUNTIME_KEY_B64) return null;
  try {
    const key = Buffer.from(RUNTIME_KEY_B64, "base64");
    if (key.length !== 32) return null;
    const iv = crypto.randomBytes(12);
    const cipher = crypto.createCipheriv("aes-256-gcm", key, iv);
    const pt = Buffer.from(JSON.stringify(obj), "utf8");
    const ct = Buffer.concat([cipher.update(pt), cipher.final()]);
    const tag = cipher.getAuthTag();
    const b = (buf) => buf.toString("base64url");
    return [RUNTIME_BLOB_PREFIX, b(iv), b(ct), b(tag)].join(".");
  } catch (err) {
    console.error("[vibe-bridge] runtime encrypt failed:", err.message);
    return null;
  }
}

// What to attach to a `result` push for the runtime payload. When a key is
// present we send ONLY the encrypted blob (plus a non-sensitive `canRevert`
// boolean the server/self-test need); the server never receives the plaintext
// diff. With no key we still send no plaintext — the card just stays hidden
// until the phone syncs the key.
function runtimeResultField(agentRuntime) {
  const canRevert = !!(agentRuntime && agentRuntime.controls && agentRuntime.controls.canRevert);
  const enc = encryptRuntimeBlob(agentRuntime);
  return enc ? { agentRuntimeEnc: enc, canRevert } : { canRevert };
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

function hasExplicitRepositorySelection() {
  return !!(
    ARGS.repos.length ||
    ARGS.repoRoots.length ||
    ARGS.cwd ||
    splitEnvList(process.env.VIBE_BRIDGE_REPOS).length ||
    splitEnvList(process.env.VIBE_BRIDGE_REPO_ROOTS).length
  );
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
  if (map.size === 0 && !hasExplicitRepositorySelection()) {
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
  // The QR carries the public request_id plus the end-to-end runtime key in the
  // fragment. The key never reaches the server (the phone authorizes by
  // request_id only); it travels phone-ward purely over this scanned QR.
  renderQR(`vibegram-pair:${request_id}#${RUNTIME_KEY_B64 || ""}`);
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
const runningTasks = new Map(); // taskKey -> { child, provider, chatId, taskId, startedAt }
const finishedTasks = new Map(); // taskKey -> { provider, chatId, taskId, repo, runtime, finishedAt }
const modelBySession = new Map(); // provider:chatId -> model selected from mobile
const lastRuntimeBySession = new Map(); // provider:chatId -> last completed runtime payload
const capabilitiesByProvider = new Map(); // provider -> latest tools/slash/MCP metadata

const BRIDGE_COMMANDS = [
  "/commands",
  "/help",
  "/usage",
  "/model [name|default]",
  "/compact",
  "/status",
];

const DEFAULT_CLAUDE_SLASH_COMMANDS = [
  "clear",
  "compact",
  "config",
  "context",
  "init",
  "review",
  "security-review",
  "usage",
  "usage-credits",
  "extra-usage",
  "insights",
  "goal",
];

const DEFAULT_CLAUDE_CLI_COMMANDS = [
  "agents",
  "auth",
  "auto-mode",
  "doctor",
  "mcp",
  "plugin",
  "project",
  "ultrareview",
  "update",
];

const DEFAULT_CODEX_CLI_COMMANDS = [
  "exec",
  "review",
  "login",
  "logout",
  "mcp",
  "plugin",
  "mcp-server",
  "app-server",
  "remote-control",
  "app",
  "doctor",
  "apply",
  "resume",
  "cloud",
];

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
//   ask_auto    — safe automatic execution for noninteractive mobile runs
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
  if (["ask_auto", "ask-auto", "askauto", "auto_ask", "auto-ask"].includes(raw)) {
    return "ask_auto";
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

// Resume is now EXPLICIT and per-message. The phone attaches a session/thread id
// only when the user picks "continue a session" in the input bar; absent that, every
// run starts a FRESH session (new task per message). The bridge no longer
// auto-resumes by chatId. `sessionByChat` is still captured below for /compact and
// result reporting, but it does NOT drive --resume anymore.
function resumeIdFor(task) {
  if (!task) return null;
  const raw =
    task.resumeSessionId ||
    task.agentBridgeResumeSessionId ||
    task.resumeThreadId ||
    task.agentBridgeResumeThreadId ||
    null;
  const trimmed = raw == null ? "" : String(raw).trim();
  return trimmed || null;
}

function claudePermissionMode(task) {
  if (process.env.VIBE_CLAUDE_PERMISSION_MODE) return process.env.VIBE_CLAUDE_PERMISSION_MODE;
  switch (workModeFor(task)) {
    case "full_access":
      return "bypassPermissions";
    case "allow_edits":
    case "ask_auto":
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
    case "ask_auto":
      return "workspace-write";
    case "allow_edits":
      return "workspace-write";
    default:
      return "read-only";
  }
}

function modelFor(provider, chatId, task) {
  const requested = task && (task.model || task.agentModel || task.agentBridgeModel);
  if (requested && String(requested).trim()) return String(requested).trim();
  const stored = modelBySession.get(sessionKey(provider, chatId));
  if (stored && String(stored).trim()) return String(stored).trim();
  const envModel = provider === "claude" ? process.env.VIBE_CLAUDE_MODEL : process.env.VIBE_CODEX_MODEL;
  return envModel && String(envModel).trim() ? String(envModel).trim() : null;
}

function buildCommand(provider, prompt, chatId, task) {
  const cleaned = stripReservedMention(prompt, provider);
  const model = modelFor(provider, chatId, task);
  if (provider === "claude") {
    const mode = claudePermissionMode(task);
    const args = ["-p", "--output-format", "stream-json", "--permission-mode", mode];
    const resumeId = resumeIdFor(task);
    if (resumeId) args.push("--resume", resumeId);
    args.push("--verbose");
    if (model) args.push("--model", model);
    args.push("--", cleaned);
    return { cmd: process.env.VIBE_CLAUDE_COMMAND || "claude", args };
  }
  if (provider === "codex") {
    const sandbox = codexSandbox(task);
    const resumeId = resumeIdFor(task);
    // `codex exec resume <thread-id>` continues a prior thread; a bare `codex exec`
    // starts fresh. Resume needs the persisted thread on disk, so we must NOT pass
    // `--ephemeral` in that case (ephemeral runs leave nothing to resume).
    const args = ["exec"];
    if (resumeId) args.push("resume", resumeId);
    args.push("--json", "--sandbox", sandbox, "--skip-git-repo-check");
    if (!resumeId) args.push("--ephemeral");
    if (model) args.push("--model", model);
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

function taskIdFor(task) {
  const raw =
    task &&
    (task.taskId ||
      task.agentTaskId ||
      task.messageId ||
      task.replyToId ||
      task.id ||
      `${task.provider || "agent"}:${task.chatId || "chat"}:${Date.now()}`);
  return String(raw || crypto.randomUUID());
}

function taskKey(provider, chatId, taskId) {
  return `${provider || "agent"}:${chatId || "chat"}:${taskId || "-"}`;
}

function sessionKey(provider, chatId) {
  return `${provider || "agent"}:${chatId || "chat"}`;
}

function taskLookupCandidates(provider, chatId, taskId, records) {
  const candidates = [];
  if (provider && chatId && taskId) candidates.push(taskKey(provider, chatId, taskId));
  if (provider && chatId) {
    for (const key of records.keys()) {
      if (key.startsWith(`${provider}:${chatId}:`)) candidates.push(key);
    }
  }
  return candidates;
}

function rememberFinishedTask(key, record) {
  finishedTasks.set(key, record);
  while (finishedTasks.size > 120) {
    const oldest = finishedTasks.keys().next().value;
    if (!oldest) break;
    finishedTasks.delete(oldest);
  }
}

function rememberRuntime(provider, chatId, runtime) {
  if (!provider || !chatId || !runtime) return;
  lastRuntimeBySession.set(sessionKey(provider, chatId), runtime);
  if (
    runtime.availableTools ||
    runtime.slashCommands ||
    runtime.mcpServers ||
    runtime.providerCommands
  ) {
    capabilitiesByProvider.set(provider, {
      availableTools: runtime.availableTools || [],
      slashCommands: runtime.slashCommands || [],
      mcpServers: runtime.mcpServers || [],
      providerCommands: runtime.providerCommands || [],
      cliCommands: runtime.cliCommands || [],
    });
  }
}

function runGit(cwd, args, maxBytes = MAX_DIFF_BYTES) {
  try {
    return execFileSync("git", args, {
      cwd,
      encoding: "utf8",
      timeout: 10_000,
      maxBuffer: maxBytes + 4096,
      stdio: ["ignore", "pipe", "ignore"],
    }).slice(0, maxBytes);
  } catch (_) {
    return "";
  }
}

function parseNameStatus(text) {
  const statuses = new Map();
  for (const line of String(text || "").split("\n")) {
    if (!line.trim()) continue;
    const parts = line.split("\t");
    const status = parts[0] || "";
    const file = parts[parts.length - 1] || "";
    if (file) statuses.set(file, status);
  }
  return statuses;
}

function parseNumstat(text, statuses) {
  const files = [];
  let added = 0;
  let removed = 0;
  for (const line of String(text || "").split("\n")) {
    if (!line.trim()) continue;
    const parts = line.split("\t");
    if (parts.length < 3) continue;
    const add = parseInt(parts[0], 10);
    const del = parseInt(parts[1], 10);
    const file = parts.slice(2).join("\t");
    const additions = Number.isFinite(add) ? add : 0;
    const deletions = Number.isFinite(del) ? del : 0;
    added += additions;
    removed += deletions;
    files.push({
      path: file,
      name: path.basename(file),
      status: statuses.get(file) || "M",
      additions,
      deletions,
    });
  }
  return { files, added, removed };
}

function untrackedFiles(cwd, existingPaths) {
  const output = runGit(cwd, ["ls-files", "--others", "--exclude-standard"], 64 * 1024);
  const files = [];
  for (const file of output.split("\n").map((line) => line.trim()).filter(Boolean)) {
    if (existingPaths.has(file)) continue;
    const absolute = path.join(cwd, file);
    let additions = 0;
    try {
      const stat = fs.statSync(absolute);
      if (stat.isFile() && stat.size <= MAX_UNTRACKED_FILE_BYTES) {
        const content = fs.readFileSync(absolute, "utf8");
        additions = content.trimEnd() ? content.trimEnd().split("\n").length : 0;
      }
    } catch (_) {
      additions = 0;
    }
    files.push({
      path: file,
      name: path.basename(file),
      status: "A?",
      additions,
      deletions: 0,
    });
  }
  return files;
}

function diffFilePath(file) {
  return String(file || "").replace(/[\r\n]/g, "");
}

function untrackedPatch(cwd, files, maxBytes) {
  const chunks = [];
  let used = 0;
  let truncated = false;

  for (const file of files) {
    if (used >= maxBytes) {
      truncated = true;
      break;
    }

    const relativePath = diffFilePath(file.path);
    if (!relativePath) continue;

    const absolute = path.join(cwd, relativePath);
    let content;
    try {
      const stat = fs.statSync(absolute);
      if (!stat.isFile() || stat.size > MAX_UNTRACKED_FILE_BYTES) continue;
      const raw = fs.readFileSync(absolute);
      if (raw.includes(0)) continue;
      content = raw.toString("utf8");
    } catch (_) {
      continue;
    }

    const normalized = content.endsWith("\n") ? content.slice(0, -1) : content;
    const lines = normalized.length ? normalized.split("\n") : [];
    const header =
      `diff --git a/${relativePath} b/${relativePath}\n` +
      "new file mode 100644\n" +
      "index 0000000..0000000\n" +
      "--- /dev/null\n" +
      `+++ b/${relativePath}\n` +
      `@@ -0,0 +1,${lines.length} @@\n`;
    const body = lines.map((line) => `+${line}`).join("\n") + (lines.length ? "\n" : "");
    const chunk = header + body;
    const remaining = maxBytes - used;

    if (chunk.length > remaining) {
      chunks.push(chunk.slice(0, remaining));
      used = maxBytes;
      truncated = true;
      break;
    }

    chunks.push(chunk);
    used += chunk.length;
  }

  return { patch: chunks.join(""), truncated };
}

function gitSnapshot(cwd) {
  const inside = runGit(cwd, ["rev-parse", "--is-inside-work-tree"], 128).trim() === "true";
  if (!inside) return { git: false, dirty: false, files: [], additions: 0, deletions: 0, patch: "" };

  const statusText = runGit(cwd, ["status", "--porcelain=v1"], 64 * 1024);
  const statuses = parseNameStatus(runGit(cwd, ["diff", "--name-status", "HEAD", "--"], 64 * 1024));
  const parsed = parseNumstat(runGit(cwd, ["diff", "--numstat", "HEAD", "--"], 64 * 1024), statuses);
  const existingPaths = new Set(parsed.files.map((file) => file.path));
  const untracked = untrackedFiles(cwd, existingPaths);
  const files = [...parsed.files, ...untracked]
    .sort((a, b) => (b.additions + b.deletions) - (a.additions + a.deletions))
    .slice(0, MAX_DIFF_FILES);
  const additions = files.reduce((sum, file) => sum + (file.additions || 0), 0);
  const deletions = files.reduce((sum, file) => sum + (file.deletions || 0), 0);
  const trackedPatch = runGit(
    cwd,
    ["diff", "--no-ext-diff", "--unified=80", "HEAD", "--"],
    MAX_DIFF_BYTES
  );
  const remainingPatchBytes = Math.max(0, MAX_DIFF_BYTES - trackedPatch.length);
  const newFilePatch = untrackedPatch(
    cwd,
    files.filter((file) => file.status === "A?"),
    remainingPatchBytes
  );
  const patch = trackedPatch + newFilePatch.patch;

  return {
    git: true,
    dirty: statusText.trim().length > 0,
    statusCount: statusText.split("\n").filter((line) => line.trim()).length,
    files,
    additions,
    deletions,
    patch,
    patchTruncated: patch.length >= MAX_DIFF_BYTES || newFilePatch.truncated,
  };
}

function compactCommand(cmd, args) {
  return [cmd, ...(args || [])].join(" ").replace(/\s+/g, " ").slice(0, 1200);
}

function decodedOutputEvents(output) {
  const events = [];
  for (const line of String(output || "").split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || !trimmed.startsWith("{") && !trimmed.startsWith("[")) continue;
    try {
      const parsed = JSON.parse(trimmed);
      if (Array.isArray(parsed)) {
        for (const item of parsed) {
          if (item && typeof item === "object") events.push(item);
        }
      } else if (parsed && typeof parsed === "object") {
        events.push(parsed);
      }
    } catch (_) {}
  }
  return events;
}

function compactStringList(value, limit = 40) {
  if (!Array.isArray(value)) return [];
  return value
    .map((item) => String(item || "").trim())
    .filter(Boolean)
    .filter((item, index, arr) => arr.indexOf(item) === index)
    .slice(0, limit);
}

function compactMcpServers(value) {
  if (!Array.isArray(value)) return [];
  return value
    .filter((item) => item && typeof item === "object")
    .map((server) => ({
      name: String(server.name || "").trim(),
      status: String(server.status || "").trim(),
    }))
    .filter((server) => server.name)
    .slice(0, 20);
}

function numberValue(...values) {
  for (const value of values) {
    if (typeof value === "number" && Number.isFinite(value)) return value;
    if (typeof value === "string" && value.trim()) {
      const parsed = Number(value);
      if (Number.isFinite(parsed)) return parsed;
    }
  }
  return undefined;
}

function compactUsage(raw, event) {
  if (!raw || typeof raw !== "object") return null;
  const usage = {
    inputTokens: numberValue(raw.input_tokens, raw.inputTokens),
    cachedInputTokens: numberValue(raw.cached_input_tokens, raw.cache_read_input_tokens, raw.cachedInputTokens, raw.cacheReadInputTokens),
    cacheCreationInputTokens: numberValue(raw.cache_creation_input_tokens, raw.cacheCreationInputTokens),
    outputTokens: numberValue(raw.output_tokens, raw.outputTokens),
    reasoningOutputTokens: numberValue(raw.reasoning_output_tokens, raw.reasoningOutputTokens),
    totalCostUsd: numberValue(raw.total_cost_usd, raw.costUSD, raw.costUsd, event && event.total_cost_usd),
    durationMs: numberValue(event && event.duration_ms),
    durationApiMs: numberValue(event && event.duration_api_ms),
    ttftMs: numberValue(event && event.ttft_ms),
    ttftStreamMs: numberValue(event && event.ttft_stream_ms),
    numTurns: numberValue(event && event.num_turns),
  };
  for (const key of Object.keys(usage)) {
    if (usage[key] === undefined) delete usage[key];
  }
  return Object.keys(usage).length ? usage : null;
}

function providerCommandCatalog(provider, metadata = {}) {
  return {
    bridge: BRIDGE_COMMANDS,
    slash: provider === "claude"
      ? compactStringList(metadata.slashCommands || DEFAULT_CLAUDE_SLASH_COMMANDS, 80)
      : compactStringList(metadata.slashCommands || [], 80),
    cli: provider === "claude"
      ? compactStringList(metadata.cliCommands || DEFAULT_CLAUDE_CLI_COMMANDS, 80)
      : compactStringList(metadata.cliCommands || DEFAULT_CODEX_CLI_COMMANDS, 80),
  };
}

function providerMetadataFromOutput(provider, output, task, chatId) {
  const events = decodedOutputEvents(output);
  const metadata = {};
  if (provider === "claude") {
    const init = events.find((event) => event && event.type === "system" && event.subtype === "init") ||
      events.find((event) => Array.isArray(event.tools) || Array.isArray(event.slash_commands));
    const resultEvents = events.filter((event) => event && event.type === "result");
    const result = resultEvents[resultEvents.length - 1] || null;
    const assistantEvents = events.filter((event) => event && event.message && event.message.usage);
    const assistant = assistantEvents[assistantEvents.length - 1] || null;
    metadata.model = (result && result.model) || (init && init.model) || modelFor(provider, chatId, task);
    metadata.permissionMode = init && init.permissionMode;
    metadata.sessionId = (result && result.session_id) || (init && init.session_id);
    metadata.cliVersion = init && init.claude_code_version;
    metadata.availableTools = compactStringList((init && init.tools) || [], 80);
    metadata.slashCommands = compactStringList((init && init.slash_commands) || DEFAULT_CLAUDE_SLASH_COMMANDS, 80);
    metadata.cliCommands = DEFAULT_CLAUDE_CLI_COMMANDS;
    metadata.mcpServers = compactMcpServers(init && init.mcp_servers);
    metadata.agents = compactStringList((init && init.agents) || [], 40);
    metadata.skills = compactStringList((init && init.skills) || [], 40);
    metadata.usage = compactUsage((result && result.usage) || (assistant && assistant.message && assistant.message.usage), result || assistant);
  } else if (provider === "codex") {
    const thread = events.find((event) => event && event.type === "thread.started");
    const turnEvents = events.filter((event) => event && event.type === "turn.completed");
    const turn = turnEvents[turnEvents.length - 1] || null;
    metadata.model = modelFor(provider, chatId, task);
    metadata.threadId = thread && thread.thread_id;
    metadata.cliVersion = "codex-cli";
    metadata.availableTools = [];
    metadata.slashCommands = [];
    metadata.cliCommands = DEFAULT_CODEX_CLI_COMMANDS;
    metadata.mcpServers = [];
    metadata.usage = compactUsage(turn && turn.usage, turn);
  }

  const catalog = providerCommandCatalog(provider, metadata);
  metadata.providerCommands = catalog.bridge;
  metadata.slashCommands = catalog.slash;
  metadata.cliCommands = catalog.cli;
  return metadata;
}

function parseBridgeCommand(prompt) {
  const text = String(prompt || "").trim();
  if (!text.startsWith("/")) return null;
  const firstLine = text.split(/\r?\n/, 1)[0].trim();
  const match = firstLine.match(/^\/([a-z][a-z0-9_-]*)(?:\s+(.*))?$/i);
  if (!match) return null;
  const name = match[1].toLowerCase();
  if (!["commands", "help", "usage", "model", "compact", "status"].includes(name)) return null;
  return { name, args: (match[2] || "").trim(), raw: firstLine };
}

function formatUsage(runtime) {
  const usage = runtime && runtime.usage;
  if (!usage) return "No usage has been recorded for this chat yet. Run one agent task first.";
  const parts = [];
  if (usage.inputTokens != null) parts.push(`input ${usage.inputTokens}`);
  if (usage.cachedInputTokens != null) parts.push(`cached ${usage.cachedInputTokens}`);
  if (usage.outputTokens != null) parts.push(`output ${usage.outputTokens}`);
  if (usage.reasoningOutputTokens != null) parts.push(`reasoning ${usage.reasoningOutputTokens}`);
  if (usage.totalCostUsd != null) parts.push(`cost $${Number(usage.totalCostUsd).toFixed(4)}`);
  if (usage.ttftMs != null) parts.push(`ttft ${(Number(usage.ttftMs) / 1000).toFixed(1)}s`);
  if (usage.durationMs != null) parts.push(`duration ${(Number(usage.durationMs) / 1000).toFixed(1)}s`);
  return parts.length ? parts.join(" · ") : "Usage was present, but did not include token totals.";
}

function formatCommands(provider) {
  const caps = capabilitiesByProvider.get(provider) || {};
  const catalog = providerCommandCatalog(provider, caps);
  const lines = [
    "Bridge commands available from mobile:",
    ...catalog.bridge.map((cmd) => `- ${cmd}`),
    "",
  ];
  if (catalog.slash.length) {
    lines.push(`${provider === "claude" ? "Claude" : "Provider"} slash commands reported by CLI metadata:`);
    lines.push(...catalog.slash.map((cmd) => `- /${cmd}`));
    lines.push("");
  }
  if (catalog.cli.length) {
    lines.push(`${provider === "claude" ? "Claude" : "Codex"} terminal commands visible on this computer:`);
    lines.push(...catalog.cli.map((cmd) => `- ${cmd}`));
  }
  return lines.join("\n").trim();
}

function bridgeCommandOutput(provider, chatId, task, repo, command) {
  const key = sessionKey(provider, chatId);
  const currentModel = modelFor(provider, chatId, task);
  const lastRuntime = lastRuntimeBySession.get(key);
  switch (command.name) {
    case "commands":
    case "help":
      return formatCommands(provider);
    case "usage":
      return [
        `${provider} usage for this chat:`,
        formatUsage(lastRuntime),
        currentModel ? `Current model: ${currentModel}` : "Current model: provider default",
      ].join("\n");
    case "model": {
      const next = command.args.trim();
      if (!next) return `Current ${provider} model: ${currentModel || "provider default"}`;
      if (["default", "reset", "auto"].includes(next.toLowerCase())) {
        modelBySession.delete(key);
        return `${provider} model reset to provider default for this chat.`;
      }
      modelBySession.set(key, next);
      return `${provider} model set to ${next} for this chat.`;
    }
    case "compact":
      sessionByChat.delete(chatId);
      return [
        "Bridge context compacted for this chat.",
        "The next Claude request will start without the previous --resume session.",
        "Codex bridge runs are already ephemeral in this noninteractive path.",
      ].join("\n");
    case "status":
      return [
        `${provider} bridge status`,
        `repo: ${repo.name}`,
        `cwd: ${repo.cwd || repo.path}`,
        `work mode: ${workModeFor(task)}`,
        `model: ${currentModel || "provider default"}`,
        `last usage: ${formatUsage(lastRuntime)}`,
      ].join("\n");
    default:
      return null;
  }
}

function runBridgeCommand(channel, task, repo, beforeGit, command) {
  const { provider, chatId, replyToId, requesterUserId } = task;
  const taskId = taskIdFor(task || {});
  const startedAt = Date.now();
  const output = bridgeCommandOutput(provider, chatId, task, repo, command);
  if (output == null) return false;

  channel.push("progress", {
    provider,
    chatId,
    taskId,
    replyToId,
    repoId: repo.id,
    repoName: repo.name,
    cwd: repo.cwd || repo.path,
    workMode: workModeFor(task),
    model: modelFor(provider, chatId, task) || "provider default",
    stage: "bridge_command",
    command: command.raw,
    line: JSON.stringify({
      type: "vibe_bridge_command",
      provider,
      taskId,
      command: command.raw,
    }),
  });

  const durationMs = Date.now() - startedAt;
  const afterGit = gitSnapshot(repo.cwd || repo.path || DEFAULT_CWD);
  const built = { cmd: "vibe-bridge", args: [command.raw] };
  const agentRuntime = runtimePayload({
    provider,
    task,
    taskId,
    repo,
    built,
    exitStatus: 0,
    durationMs,
    before: beforeGit,
    after: afterGit,
    canceled: false,
    output: "",
  });
  rememberRuntime(provider, chatId, agentRuntime);
  channel.push("result", {
    provider,
    chatId,
    taskId,
    output,
    exitStatus: 0,
    durationMs,
    replyToId,
    requesterUserId,
    repoId: repo.id,
    repoName: repo.name,
    cwd: repo.cwd || repo.path,
    workMode: workModeFor(task),
    ...runtimeResultField(agentRuntime),
  });
  return true;
}

function runtimePayload({
  provider,
  task,
  taskId,
  repo,
  built,
  exitStatus,
  durationMs,
  before,
  after,
  canceled,
  output,
}) {
  const fileSummary = after && after.git ? after : { files: [], additions: 0, deletions: 0, patch: "" };
  const metadata = providerMetadataFromOutput(provider, output || "", task, task && task.chatId);
  const payload = {
    taskId,
    provider,
    status: canceled ? "stopped" : exitStatus === 0 ? "done" : "failed",
    repoId: repo.id,
    repoName: repo.name,
    cwd: repo.cwd || repo.path,
    workMode: workModeFor(task),
    durationMs,
    dirtyBefore: !!(before && before.dirty),
    dirtyBeforeCount: (before && before.statusCount) || 0,
    exitStatus,
    command: {
      executable: built.cmd,
      args: built.args,
      display: compactCommand(built.cmd, built.args),
    },
    diff: {
      git: !!(after && after.git),
      filesChanged: fileSummary.files.length,
      additions: fileSummary.additions || 0,
      deletions: fileSummary.deletions || 0,
      files: fileSummary.files || [],
      patch: fileSummary.patch || "",
      patchTruncated: !!fileSummary.patchTruncated,
    },
    controls: {
      canCancel: false,
      canRevert: !!(
        after &&
        after.git &&
        before &&
        !before.dirty &&
        fileSummary.files &&
        fileSummary.files.length > 0
      ),
    },
  };

  payload.model = metadata.model || modelFor(provider, task && task.chatId, task) || "provider default";
  if (metadata.permissionMode) payload.permissionMode = metadata.permissionMode;
  if (metadata.sessionId) payload.sessionId = metadata.sessionId;
  if (metadata.threadId) payload.threadId = metadata.threadId;
  if (metadata.cliVersion) payload.cliVersion = metadata.cliVersion;
  if (metadata.usage) payload.usage = metadata.usage;
  if (metadata.availableTools && metadata.availableTools.length) payload.availableTools = metadata.availableTools;
  if (metadata.slashCommands && metadata.slashCommands.length) payload.slashCommands = metadata.slashCommands;
  if (metadata.cliCommands && metadata.cliCommands.length) payload.cliCommands = metadata.cliCommands;
  if (metadata.providerCommands && metadata.providerCommands.length) payload.providerCommands = metadata.providerCommands;
  if (metadata.mcpServers && metadata.mcpServers.length) payload.mcpServers = metadata.mcpServers;
  if (metadata.agents && metadata.agents.length) payload.agents = metadata.agents;
  if (metadata.skills && metadata.skills.length) payload.skills = metadata.skills;
  return payload;
}

function safeRepoPath(cwd, relativePath) {
  const clean = diffFilePath(relativePath);
  if (!clean || path.isAbsolute(clean)) return null;
  const base = path.resolve(cwd);
  const absolute = path.resolve(base, clean);
  if (absolute === base || !absolute.startsWith(base + path.sep)) return null;
  return absolute;
}

function restoreTrackedFiles(cwd, files) {
  if (!files.length) return;
  const args = ["restore", "--staged", "--worktree", "--", ...files];
  try {
    execFileSync("git", args, { cwd, stdio: "ignore", timeout: 10_000 });
  } catch (_) {
    execFileSync("git", ["checkout", "--", ...files], { cwd, stdio: "ignore", timeout: 10_000 });
  }
}

function revertFinishedTask(channel, payload) {
  const provider = payload.provider || payload.agentWorkerProvider || payload.agentBridgeProvider;
  const chatId = payload.chatId || payload.chat_id;
  const taskId = payload.taskId || payload.agentTaskId || payload.messageId;
  const candidates = taskLookupCandidates(provider, chatId, taskId, finishedTasks);
  const key = candidates.find((candidate) => finishedTasks.has(candidate));
  const record = key && finishedTasks.get(key);

  if (!record) {
    channel.push("control_result", { ok: false, reason: "task_not_found", action: "revert", provider, chatId, taskId });
    return;
  }

  const runtime = record.runtime || {};
  if (!runtime.controls || runtime.controls.canRevert !== true) {
    channel.push("control_result", {
      ok: false,
      reason: runtime.dirtyBefore ? "repo_was_dirty_before_task" : "task_not_revertible",
      action: "revert",
      provider: record.provider,
      chatId: record.chatId,
      taskId: record.taskId,
    });
    return;
  }

  const cwd = record.repo.cwd || record.repo.path;
  const files = (runtime.diff && Array.isArray(runtime.diff.files) ? runtime.diff.files : []).filter(
    (file) => file && file.path
  );
  const tracked = files
    .filter((file) => file.status !== "A?")
    .map((file) => diffFilePath(file.path))
    .filter(Boolean);
  const untracked = files.filter((file) => file.status === "A?");

  try {
    restoreTrackedFiles(cwd, tracked);
    for (const file of untracked) {
      const absolute = safeRepoPath(cwd, file.path);
      if (absolute) fs.rmSync(absolute, { recursive: true, force: true });
    }
    const after = gitSnapshot(cwd);
    finishedTasks.delete(key);
    channel.push("control_result", {
      ok: true,
      action: "revert",
      provider: record.provider,
      chatId: record.chatId,
      taskId: record.taskId,
      repoId: record.repo.id,
      repoName: record.repo.name,
      cwd,
      diffAfter: {
        filesChanged: after.files.length,
        additions: after.additions || 0,
        deletions: after.deletions || 0,
      },
    });
  } catch (err) {
    channel.push("control_result", {
      ok: false,
      reason: err.message || "revert_failed",
      action: "revert",
      provider: record.provider,
      chatId: record.chatId,
      taskId: record.taskId,
    });
  }
}

function bridgeStatusPayload() {
  return {
    deviceLabel: ARGS.label || os.hostname(),
    cwd: DEFAULT_CWD,
    repositories: ADVERTISED_REPOSITORIES,
    runningTasks: runningTaskSummaries(),
    permissions: {
      claude: {
        permissionMode: process.env.VIBE_CLAUDE_PERMISSION_MODE || "per-task",
        command: process.env.VIBE_CLAUDE_COMMAND || "claude",
      },
      codex: {
        sandbox: process.env.VIBE_CODEX_SANDBOX || "per-task",
        command: process.env.VIBE_CODEX_COMMAND || "codex",
      },
      workModes: ["ask", "ask_auto", "read_only", "allow_edits", "full_access"],
    },
  };
}

function runningTaskSummaries() {
  const now = Date.now();
  return Array.from(runningTasks.values()).map((entry) => ({
    provider: entry.provider,
    chatId: entry.chatId,
    taskId: entry.taskId,
    sessionId: entry.sessionId || null,
    topic: cleanTopicCandidate(entry.prompt) || clip(`${entry.provider || "Agent"} task`, 80),
    repoId: entry.repo && entry.repo.id,
    repoName: entry.repo && entry.repo.name,
    project: entry.repo && (entry.repo.cwd || entry.repo.path),
    projectName: entry.repo && entry.repo.name,
    cwd: entry.cwd,
    workMode: entry.workMode,
    model: entry.model || null,
    startedAt: new Date(entry.startedAt).toISOString(),
    durationMs: Math.max(0, now - (entry.startedAt || now)),
    command: entry.command,
    pendingCommand: entry.command,
  }));
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

function chooseFolderWithSystemPicker() {
  if (process.platform !== "darwin") return null;
  try {
    return execFileSync(
      "osascript",
      ["-e", 'POSIX path of (choose folder with prompt "Select a project folder for Vibe Bridge")'],
      { encoding: "utf8" }
    ).trim();
  } catch (_) {
    return null;
  }
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

  console.log("\n[vibe-bridge] Choose project(s) for @claude / @codex:\n");
  found.forEach((r, i) => {
    console.log(`  ${String(i + 1).padStart(2)}. ${r.name}   ${r.path}`);
  });
  console.log("\n  A. All discovered repos");
  console.log(`  C. Current folder   ${process.cwd()}`);
  console.log("  P. Enter a project path");
  if (process.platform === "darwin") console.log("  F. Select a folder");
  console.log("\n  Enter a number, numbers like 1,3, or one of the options above. Blank = the first repo.");
  const answer = (await promptLine("  Selection: ")).trim();

  if (!answer) return [found[0].path];
  const lower = answer.toLowerCase();
  if (lower === "a" || lower === "all") return found.map((r) => r.path);
  if (lower === "c" || lower === "current") return [process.cwd()];
  if (lower === "p" || lower === "path") {
    const custom = (await promptLine("  Project path: ")).trim();
    return [custom || found[0].path];
  }
  if (lower === "f" || lower === "file" || lower === "folder" || lower === "select") {
    const selected = chooseFolderWithSystemPicker();
    if (selected) return [selected];
    const custom = (await promptLine("  Project path: ")).trim();
    return [custom || found[0].path];
  }
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
  const explicit = hasExplicitRepositorySelection();

  let picked = !explicit && Array.isArray(config.repos) ? config.repos.slice() : [];

  const interactive = process.stdin.isTTY && !ARGS.serviceRun && !ARGS.noPick;
  const shouldPrompt = interactive && (ARGS.pick || ARGS.all || (!explicit && picked.length === 0));

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
  if (explicit && ADVERTISED_REPOSITORIES.length === 0) {
    throw new Error("No valid repositories matched --repo/--cwd/--repo-root. Refusing to fall back to the current folder.");
  }
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

function shouldUseBackgroundByDefault() {
  if (ARGS.serviceRun || ARGS.foreground) return false;
  if (ARGS.selfTest || ARGS.selfTestRevert || ARGS.selfTestSequence) return false;
  if (ARGS.uninstall || ARGS.status || ARGS.logout) return false;
  return process.platform === "darwin";
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

// Forward a line live if it carries assistant TEXT or tool activity, so the
// server can stream a live bubble (not just the final batch). System/init lines
// are skipped. The server is the source of truth for parsing — we stay thin.
function streamable(line) {
  return (
    looksToolish(line) ||
    line.includes('"text"') || // claude assistant text blocks
    line.includes('"assistant"') ||
    line.includes('"agent_message"') || // codex agent text
    line.includes('"item"') // codex item events
  );
}

function runTask(channel, task) {
  const { provider, chatId, prompt, replyToId, requesterUserId } = task;
  const taskId = taskIdFor(task || {});
  console.log(
    `[vibe-bridge] run_task received provider=${provider} chat=${chatId} ` +
      `task=${taskId} ` +
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
  console.log(`[vibe-bridge] run ${provider} chat=${chatId} task=${taskId} cwd=${cwd}`);

  const startedAt = Date.now();
  const beforeGit = gitSnapshot(cwd);
  const bridgeCommand = parseBridgeCommand(prompt);
  if (bridgeCommand && runBridgeCommand(channel, task, repo, beforeGit, bridgeCommand)) {
    return;
  }

  let child;
  try {
    child = spawn(built.cmd, built.args, { cwd, stdio: ["ignore", "pipe", "pipe"] });
  } catch (err) {
    channel.push("error", { provider, chatId, message: `Could not start ${built.cmd}: ${err.message}`, replyToId });
    return;
  }

  const key = taskKey(provider, chatId, taskId);
  runningTasks.set(key, {
    child,
    provider,
    chatId,
    taskId,
    sessionId: resumeIdFor(task),
    prompt,
    repo,
    cwd,
    workMode: workModeFor(task),
    model: modelFor(provider, chatId, task),
    command: compactCommand(built.cmd, built.args),
    startedAt,
  });
  pushBridgeStatus(channel);
  channel.push("progress", {
    provider,
    chatId,
    taskId,
    replyToId,
    repoId: repo.id,
    repoName: repo.name,
    cwd,
    workMode: workModeFor(task),
    model: modelFor(provider, chatId, task) || "provider default",
    stage: "started",
    command: compactCommand(built.cmd, built.args),
    line: JSON.stringify({
      type: "vibe_bridge_started",
      provider,
      taskId,
      repoId: repo.id,
      repoName: repo.name,
      cwd,
      workMode: workModeFor(task),
      command: compactCommand(built.cmd, built.args),
    }),
  });
  let output = "";
  let lineBuf = "";
  let progressCount = 1;
  let canceled = false;

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
      if (progressCount < MAX_PROGRESS_LINES && line.length <= MAX_LINE_BYTES && streamable(line)) {
        progressCount++;
        channel.push("progress", {
          provider,
          chatId,
          taskId,
          replyToId,
          repoId: repo.id,
          repoName: repo.name,
          cwd,
          workMode: workModeFor(task),
          model: modelFor(provider, chatId, task) || "provider default",
          line,
        });
      }
    }
  };

  child.stdout.on("data", onChunk);
  child.stderr.on("data", onChunk);

  child.on("error", (err) => {
    channel.push("error", { provider, chatId, message: `${built.cmd} failed: ${err.message}`, replyToId });
  });

  child.on("close", (code) => {
    runningTasks.delete(key);
    pushBridgeStatus(channel);
    const durationMs = Date.now() - startedAt;
    canceled = canceled || child.signalCode === "SIGTERM" || child.signalCode === "SIGKILL";
    const afterGit = gitSnapshot(cwd);
    const exitStatus = code == null ? (canceled ? 130 : 1) : code;
    console.log(
      `[vibe-bridge] done ${provider} chat=${chatId} task=${taskId} exit=${exitStatus} ${durationMs}ms`
    );
    const agentRuntime = runtimePayload({
      provider,
      task,
      taskId,
      repo,
      built,
      exitStatus,
      durationMs,
      before: beforeGit,
      after: afterGit,
      canceled,
      output,
    });
    rememberFinishedTask(key, {
      provider,
      chatId,
      taskId,
      repo,
      runtime: agentRuntime,
      finishedAt: Date.now(),
    });
    rememberRuntime(provider, chatId, agentRuntime);
    channel.push("result", {
      provider,
      chatId,
      taskId,
      output,
      exitStatus,
      durationMs,
      replyToId,
      requesterUserId,
      repoId: repo.id,
      repoName: repo.name,
      cwd,
      workMode: workModeFor(task),
      ...runtimeResultField(agentRuntime),
    });
  });

  return {
    taskId,
    cancel() {
      canceled = true;
      try {
        child.kill("SIGTERM");
        setTimeout(() => {
          if (!child.killed) child.kill("SIGKILL");
        }, 2500).unref?.();
      } catch (_) {}
    },
  };
}

// ── Session history (Claude Code + Codex local conversation stores) ──────
//
// The phone (via the server) can ask the connected computer for the agent's
// own past conversations so they render in the Claude/Codex profile. We read
// the CLIs' local session logs read-only:
//   Claude → ~/.claude/projects/<encoded-cwd>/<session>.jsonl  (ai-title + msgs)
//   Codex  → ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl       (session_meta + msgs)
// `list` returns lightweight topic summaries; `detail` returns the transcript.

const HISTORY_LIST_LIMIT = 40;
const HISTORY_MSG_LIMIT = 250;

function clip(value, n) {
  if (typeof value !== "string") return "";
  const s = value.replace(/\s+/g, " ").trim();
  return s.length > n ? s.slice(0, n - 1) + "…" : s;
}

// A user message that is purely machine/IDE/environment scaffolding — never a topic.
function isContextMessage(text) {
  if (typeof text !== "string") return true;
  const head = text.slice(0, 400);
  return (
    /^\s*<(environment_context|user_instructions|INSTRUCTIONS|permissions|ide_opened_file|ide_selection|local-command-caveat|command-name|system-reminder|turn_aborted|turn_context|user_action)/i.test(head) ||
    /^\s*#\s*Context from my IDE/i.test(head) ||
    /^\s*AGENTS\.md instructions/i.test(head) ||
    /^\s*The following is the Codex agent history/i.test(head) ||
    /^\s*The user interrupted the previous turn/i.test(head) ||
    /## Active (file|selection)/i.test(head)
  );
}

function cleanTopicCandidate(text) {
  if (typeof text !== "string" || isContextMessage(text)) return null;
  let t = text.replace(
    /<(environment_context|user_instructions|INSTRUCTIONS|permissions|system-reminder|local-command-caveat|command-name|command-message|command-args|ide_opened_file|ide_selection)[\s\S]*?<\/\1>/gi,
    " "
  );
  t = t.replace(/^\s*(<[^>]+>\s*)+/, " ");
  for (const raw of t.split("\n")) {
    const line = raw.trim();
    if (!line || line.startsWith("<")) continue;
    if (/AGENTS\.md|caveat:/i.test(line)) continue;
    if (/^#{1,4}\s*(context from|active file|attached|open tabs?|cursor|selection|agents|environment|instructions)/i.test(line)) continue;
    if (/^(active file|cwd|shell|repo|branch)\s*:/i.test(line)) continue;
    if (/^(continue|cont|resume|keep going|go on|ok|okay|yes)$/i.test(line)) continue;
    return clip(line, 80);
  }
  return null;
}

// Strip machine-injected wrapper blocks from a message for readable display.
function cleanMessageText(text) {
  if (typeof text !== "string") return "";
  let t = text.replace(
    /<(environment_context|user_instructions|INSTRUCTIONS|permissions|system-reminder|local-command-caveat|command-name|command-message|command-args|ide_opened_file|ide_selection)[\s\S]*?<\/\1>/gi,
    " "
  );
  t = t.replace(/<\/?[a-z_-]+>/gi, " ");
  return t.replace(/[ \t]+/g, " ").replace(/\n{3,}/g, "\n\n").trim();
}

// Skip ephemeral scratch/test working dirs so the list shows real work.
function isEphemeralProject(p) {
  return /(^|\/)(private\/)?tmp\//.test(p) || /vibe-(bridge|agent)-/.test(p) || /self-test/.test(p);
}

function decodeClaudeProject(name) {
  return String(name || "").replace(/-/g, "/");
}

async function readJsonl(file, onEvent) {
  const rl = readline.createInterface({ input: fs.createReadStream(file), crlfDelay: Infinity });
  try {
    for await (const line of rl) {
      if (!line.trim()) continue;
      let ev;
      try { ev = JSON.parse(line); } catch { continue; }
      if (onEvent(ev) === false) break;
    }
  } finally {
    rl.close();
  }
}

// — Claude —
async function claudeSummary(file) {
  let topic = null, firstUser = null, lastTs = null, messages = 0;
  await readJsonl(file, (ev) => {
    const t = ev.type;
    if (t === "ai-title" && ev.aiTitle) topic = ev.aiTitle;
    else if (t === "user" || t === "assistant") {
      messages++;
      if (ev.timestamp) lastTs = ev.timestamp;
      if (t === "user" && !firstUser) {
        const c = ev.message && ev.message.content;
        if (typeof c === "string") {
          const clean = cleanTopicCandidate(c);
          if (clean) firstUser = clean;
        }
      }
    }
  });
  return { topic: topic || firstUser || "Untitled", lastTs, messages };
}

function claudeSessionFiles() {
  const root = path.join(os.homedir(), ".claude", "projects");
  const out = [];
  if (!fs.existsSync(root)) return out;
  for (const proj of fs.readdirSync(root)) {
    const projPath = decodeClaudeProject(proj);
    if (isEphemeralProject(projPath)) continue;
    const projDir = path.join(root, proj);
    let entries;
    try { entries = fs.readdirSync(projDir); } catch { continue; }
    for (const f of entries) {
      if (!f.endsWith(".jsonl")) continue;
      const full = path.join(projDir, f);
      let st;
      try { st = fs.statSync(full); } catch { continue; }
      out.push({ id: f.replace(/\.jsonl$/, ""), file: full, project: projPath, mtime: st.mtimeMs });
    }
  }
  return out;
}

async function listClaude(limit) {
  const files = claudeSessionFiles().sort((a, b) => b.mtime - a.mtime).slice(0, limit);
  const results = [];
  for (const s of files) {
    const sum = await claudeSummary(s.file);
    if (sum.messages === 0) continue;
    results.push({
      provider: "claude",
      id: s.id,
      topic: sum.topic,
      project: s.project,
      projectName: path.basename(s.project),
      updatedAt: sum.lastTs || new Date(s.mtime).toISOString(),
      messageCount: sum.messages,
    });
  }
  return results;
}

async function claudeDetail(id, limit) {
  const match = claudeSessionFiles().find((s) => s.id === id);
  if (!match) return null;
  const messages = [];
  let topic = null;
  await readJsonl(match.file, (ev) => {
    if (ev.type === "ai-title" && ev.aiTitle) topic = ev.aiTitle;
    if (ev.type !== "user" && ev.type !== "assistant") return;
    const m = ev.message || {};
    let text = "";
    if (typeof m.content === "string") text = m.content;
    else if (Array.isArray(m.content)) {
      text = m.content.filter((b) => b && b.type === "text").map((b) => b.text).join("\n").trim();
    }
    text = cleanMessageText(text);
    if (!text) return;
    messages.push({ role: ev.type, text: clip(text, 4000), ts: ev.timestamp });
    if (messages.length >= limit) return false;
  });
  return { provider: "claude", id, topic: topic || (messages[0] && clip(messages[0].text, 80)) || "Untitled", project: match.project, projectName: path.basename(match.project), messages };
}

// — Codex —
function codexText(content) {
  if (!Array.isArray(content)) return "";
  return content
    .filter((b) => b && (b.type === "input_text" || b.type === "output_text") && b.text)
    .map((b) => b.text)
    .join("\n")
    .trim();
}

function codexSessionFiles() {
  const root = path.join(os.homedir(), ".codex", "sessions");
  const out = [];
  if (!fs.existsSync(root)) return out;
  (function walk(dir) {
    let entries;
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      const full = path.join(dir, e.name);
      if (e.isDirectory()) walk(full);
      else if (e.name.startsWith("rollout-") && e.name.endsWith(".jsonl")) {
        let st;
        try { st = fs.statSync(full); } catch { continue; }
        out.push({ file: full, name: e.name, mtime: st.mtimeMs });
      }
    }
  })(root);
  return out;
}

async function codexSummary(file) {
  let meta = null, topic = null, assistantTopic = null, lastTs = null, messages = 0;
  await readJsonl(file, (ev) => {
    if (ev.type === "session_meta") meta = ev.payload || {};
    else if (ev.type === "response_item" && ev.payload && ev.payload.type === "message") {
      const role = ev.payload.role;
      if (role !== "user" && role !== "assistant") return;
      const text = codexText(ev.payload.content);
      if (!text) return;
      messages++;
      if (ev.timestamp) lastTs = ev.timestamp;
      if (role === "user" && !topic) {
        const clean = cleanTopicCandidate(text);
        if (clean) topic = clean;
      } else if (role === "assistant" && !assistantTopic) {
        const clean = cleanTopicCandidate(text);
        if (clean) assistantTopic = clean;
      }
    }
  });
  return { meta, topic: topic || assistantTopic || "Untitled", lastTs, messages };
}

async function listCodex(limit) {
  const files = codexSessionFiles().sort((a, b) => b.mtime - a.mtime).slice(0, limit);
  const results = [];
  for (const f of files) {
    const sum = await codexSummary(f.file);
    if (sum.messages === 0) continue;
    const project = (sum.meta && sum.meta.cwd) || "";
    if (isEphemeralProject(project)) continue;
    results.push({
      provider: "codex",
      id: (sum.meta && sum.meta.id) || f.name,
      topic: sum.topic,
      project,
      projectName: project ? path.basename(project) : "",
      updatedAt: sum.lastTs || new Date(f.mtime).toISOString(),
      messageCount: sum.messages,
    });
  }
  return results;
}

async function codexDetail(id, limit) {
  // The session id is embedded in the rollout filename; fall back to meta.id.
  const files = codexSessionFiles();
  let match = files.find((f) => f.name.includes(id));
  if (!match) {
    for (const f of files) {
      const sum = await codexSummary(f.file);
      if (sum.meta && sum.meta.id === id) { match = f; break; }
    }
  }
  if (!match) return null;
  const messages = [];
  let project = "";
  await readJsonl(match.file, (ev) => {
    if (ev.type === "session_meta" && ev.payload) project = ev.payload.cwd || "";
    if (ev.type !== "response_item" || !ev.payload || ev.payload.type !== "message") return;
    const role = ev.payload.role;
    if (role !== "user" && role !== "assistant") return;
    let text = cleanMessageText(codexText(ev.payload.content));
    if (!text || isContextMessage(codexText(ev.payload.content))) return;
    messages.push({ role, text: clip(text, 4000), ts: ev.timestamp });
    if (messages.length >= limit) return false;
  });
  const topic =
    messages.map((m) => cleanTopicCandidate(m.text)).find(Boolean) ||
    "Untitled";
  return { provider: "codex", id, topic, project, projectName: project ? path.basename(project) : "", messages };
}

async function readHistory({ provider, mode, sessionId, limit }) {
  const p = String(provider || "").trim().toLowerCase();
  const wantDetail = String(mode || "").toLowerCase() === "detail" || !!sessionId;
  if (wantDetail) {
    const cap = limit || HISTORY_MSG_LIMIT;
    if (p === "codex") return { mode: "detail", session: await codexDetail(sessionId, cap) };
    return { mode: "detail", session: await claudeDetail(sessionId, cap) };
  }
  const cap = limit || HISTORY_LIST_LIMIT;
  if (p === "codex") return { mode: "list", sessions: await listCodex(cap) };
  return { mode: "list", sessions: await listClaude(cap) };
}

function handleHistoryRequest(channel, payload) {
  const provider = payload.provider || payload.agentBridgeProvider || "claude";
  const requestId = payload.requestId || payload.request_id || crypto.randomUUID();
  const chatId = payload.chatId || payload.chat_id || null;
  const echo = { requestId, provider, chatId, requesterUserId: payload.requesterUserId || payload.requester_user_id || null };

  readHistory({
    provider,
    mode: payload.mode,
    sessionId: payload.sessionId || payload.session_id,
    limit: payload.limit,
  })
    .then((result) => {
      channel.push("history_result", { ok: true, ...echo, ...result });
    })
    .catch((err) => {
      channel.push("history_result", { ok: false, ...echo, message: err && err.message ? err.message : "history_failed" });
    });
}

function controlTask(channel, payload) {
  const provider = payload.provider || payload.agentWorkerProvider || payload.agentBridgeProvider;
  const chatId = payload.chatId || payload.chat_id;
  const taskId = payload.taskId || payload.agentTaskId || payload.messageId;
  const action = String(payload.action || payload.type || "").trim().toLowerCase();
  if (action === "revert") {
    revertFinishedTask(channel, payload);
    return;
  }
  if (action !== "cancel" && action !== "stop") {
    channel.push("control_result", { ok: false, reason: "unsupported_action", action, provider, chatId, taskId });
    return;
  }

  const candidates = taskLookupCandidates(provider, chatId, taskId, runningTasks);
  const key = candidates.find((candidate) => runningTasks.has(candidate));
  const entry = key && runningTasks.get(key);
  if (!entry) {
    channel.push("control_result", { ok: false, reason: "task_not_running", action, provider, chatId, taskId });
    return;
  }

  try {
    entry.child.kill("SIGTERM");
    setTimeout(() => {
      if (!entry.child.killed) entry.child.kill("SIGKILL");
    }, 2500).unref?.();
    channel.push("control_result", {
      ok: true,
      action,
      provider: entry.provider,
      chatId: entry.chatId,
      taskId: entry.taskId,
    });
  } catch (err) {
    channel.push("control_result", {
      ok: false,
      reason: err.message || "cancel_failed",
      action,
      provider: entry.provider,
      chatId: entry.chatId,
      taskId: entry.taskId,
    });
  }
}

// ── Socket / channel ────────────────────────────────────────────────

function wsUrl(server) {
  return server.replace(/^http/, "ws") + "/agent-bridge";
}

function websocketTransportUrl(server, token) {
  const params = new URLSearchParams({ token: token || "", vsn: "2.0.0" });
  return `${wsUrl(server)}/websocket?${params.toString()}`;
}

function probeBridgeToken(server, token, timeoutMs = 6000) {
  return new Promise((resolve) => {
    if (!token) return resolve({ ok: false, statusCode: 403 });

    let done = false;
    let ws;
    const finish = (result) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      try {
        if (ws && ws.readyState === WebSocket.OPEN) ws.close();
      } catch (_) {}
      resolve(result);
    };
    const timer = setTimeout(() => finish({ ok: null, reason: "timeout" }), timeoutMs);

    try {
      ws = new WebSocket(websocketTransportUrl(server, token));
      ws.on("open", () => finish({ ok: true }));
      ws.on("unexpected-response", (_request, response) =>
        finish({ ok: false, statusCode: response && response.statusCode })
      );
      ws.on("error", (error) => finish({ ok: null, reason: error && error.message }));
    } catch (error) {
      finish({ ok: null, reason: error && error.message });
    }
  });
}

function connect(server, token, userId) {
  const socket = new Phoenix.Socket(wsUrl(server), {
    params: { token },
    transport: WebSocket,
    reconnectAfterMs: (tries) => [1000, 2000, 5000, 10000][tries - 1] || 10000,
  });

  socket.onError((error) => {
    const detail =
      (error && (error.message || error.reason || error.code || error.type)) ||
      (error ? JSON.stringify(error) : "");
    console.error(`[vibe-bridge] socket error${detail ? `: ${detail}` : ""} (will retry)`);
  });
  socket.onClose((event) => {
    const detail =
      event && (event.code || event.reason)
        ? ` code=${event.code || "-"} reason=${event.reason || "-"}`
        : "";
    console.log(`[vibe-bridge] socket closed${detail} (will retry)`);
  });
  socket.connect();

  const channel = socket.channel(`bridge:${userId}`, {});
  channel.on("run_task", (task) => runTask(channel, task));
  channel.on("control_task", (payload) => controlTask(channel, payload || {}));
  channel.on("history_request", (payload) => handleHistoryRequest(channel, payload || {}));

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
          "\n   Foreground mode is active for this terminal.\n" +
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

async function runSelfTest() {
  const config = loadConfig();
  await resolveRepositories(config, () => {});
  DEFAULT_CWD =
    (ADVERTISED_REPOSITORIES[0] && ADVERTISED_REPOSITORIES[0].cwd) ||
    realDir(ARGS.cwd || process.cwd()) ||
    process.cwd();

  const provider = String(ARGS.provider || "codex").trim().toLowerCase();
  const baseTask = {
    provider,
    chatId: "self-test-chat",
    replyToId: "self-test-message",
    requesterUserId: "self-test-user",
    repoId: ADVERTISED_REPOSITORIES[0] && ADVERTISED_REPOSITORIES[0].id,
    workMode: ARGS.workMode || "allow_edits",
  };

  const runSelfTestTask = (task, shouldRevert) =>
    new Promise((resolve) => {
    let awaitingRevert = false;
    const channel = {
      state: "joined",
      push(event, payload) {
        console.log(JSON.stringify({ event, payload }));
        if (
          event === "result" &&
          shouldRevert &&
          (payload.canRevert || payload.agentRuntime?.controls?.canRevert)
        ) {
          awaitingRevert = true;
          controlTask(channel, {
            action: "revert",
            provider: task.provider,
            chatId: task.chatId,
            taskId: task.taskId,
          });
          return;
        }
        if (event === "control_result" && awaitingRevert) resolve();
        if (event === "result" || event === "error") resolve();
      },
    };
    runTask(channel, task);
    });

  if (ARGS.selfTestSequence) {
    let steps;
    try {
      steps = JSON.parse(ARGS.prompt || "[]");
    } catch (err) {
      console.error(`[vibe-bridge] --self-test-sequence expects --prompt to be a JSON array: ${err.message}`);
      process.exit(1);
    }
    if (!Array.isArray(steps) || steps.length === 0) {
      console.error("[vibe-bridge] --self-test-sequence needs at least one step.");
      process.exit(1);
    }
    for (const [index, step] of steps.entries()) {
      const stepObject = typeof step === "string" ? { prompt: step } : step || {};
      const stepProvider = String(stepObject.provider || provider).trim().toLowerCase();
      const task = {
        ...baseTask,
        provider: stepProvider,
        taskId: `self-test-task-${index + 1}`,
        prompt: stepObject.prompt || "Bridge self-test",
        workMode: stepObject.workMode || stepObject.mode || ARGS.workMode || "allow_edits",
      };
      await runSelfTestTask(task, stepObject.revert === true);
    }
    return;
  }

  await runSelfTestTask(
    {
      ...baseTask,
      taskId: "self-test-task",
      prompt: ARGS.prompt || "Bridge self-test",
    },
    ARGS.selfTestRevert
  );
}

// ── Main ────────────────────────────────────────────────────────────

async function main() {
  if (ARGS.help) {
    console.log(
      "Usage:\n" +
        "  vibegram-bridge --server <https://vibe-server>\n" +
        "      First run: shows a QR — scan it in the Vibe app (Claude/Codex → Connect → Scan),\n" +
        "      then asks which project(s) to link and starts the background service.\n\n" +
        "  vibegram-bridge --pick            re-choose which project(s) to link\n" +
        "  vibegram-bridge --all             link every git repo found near your home folder\n" +
        "  vibegram-bridge --foreground      run in this terminal instead of the background service\n" +
        "  vibegram-bridge --install         install/restart the background service\n" +
        "  vibegram-bridge --uninstall       stop & remove the background service\n" +
        "  vibegram-bridge --status          show background-service state + log path\n" +
        "  vibegram-bridge --self-test       run one local task and print bridge payload JSON\n" +
        "  vibegram-bridge --self-test-revert  also test bridge-side revert after self-test\n" +
        "  vibegram-bridge --self-test-sequence --prompt '[...]'  run JSON task list in one process\n" +
        "  vibegram-bridge --code <CODE>     manual pairing code flow\n" +
        "  vibegram-bridge --logout          remove the cached token\n\n" +
        "Non-interactive repo selection: --cwd <dir>, --repo <dir> (repeatable),\n" +
        "     --repo-root <dir> (scans 2 levels for .git). Env: VIBE_BRIDGE_REPOS,\n" +
        "     VIBE_BRIDGE_REPO_ROOTS, VIBE_CLAUDE_PERMISSION_MODE, VIBE_CODEX_SANDBOX,\n" +
        "     VIBE_CLAUDE_MODEL, VIBE_CODEX_MODEL, VIBE_CLAUDE_COMMAND, VIBE_CODEX_COMMAND"
    );
    return;
  }

  if (ARGS.selfTest || ARGS.selfTestRevert || ARGS.selfTestSequence) return runSelfTest();

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

  // Establish the end-to-end runtime key before any pairing, so the pairing QR
  // can hand it to the phone (server never sees it). Generated once, cached.
  ensureRuntimeKey(config);
  persist();

  if (ARGS.showKey) {
    console.log(
      "\n[vibe-bridge] In Vibe (Claude/Codex → Connect → Sync key), scan this to view\n" +
        "encrypted agent file-changes on your phone. The server can't read it.\n"
    );
    renderQR(runtimeKeyQRPayload());
    return;
  }

  // Background-service management (no socket needed).
  if (ARGS.uninstall) return uninstallService();
  if (ARGS.status) return serviceStatus();
  if (ARGS.install) {
    if (!config.bridge_token || !config.user_id) return installService(server, config);
    await resolveRepositories(config, persist);
    return installService(server, config);
  }

  if (ARGS.code) {
    console.log("[vibe-bridge] pairing…");
    const result = await redeemPairing(server, ARGS.code, ARGS.label);
    config.bridge_token = result.bridge_token;
    config.user_id = result.user_id;
    persist();
    console.log("[vibe-bridge] paired ✓ (token cached in ~/.vibe/bridge.json)");
    if (!ARGS.rk) {
      console.log(
        "\n[vibe-bridge] To view encrypted agent file-changes on your phone, scan this in\n" +
          "Vibe (Claude/Codex → Connect → Sync key). The server can't read it.\n"
      );
      renderQR(runtimeKeyQRPayload());
    }
  }

  if (
    config.bridge_token &&
    config.user_id &&
    process.stdin.isTTY &&
    !ARGS.serviceRun &&
    !ARGS.foreground
  ) {
    const probe = await probeBridgeToken(server, config.bridge_token);
    if (probe.ok === false && probe.statusCode === 403) {
      delete config.bridge_token;
      delete config.user_id;
      persist();
      console.log("[vibe-bridge] cached pairing expired; pairing again…");
    }
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

  if (shouldUseBackgroundByDefault()) {
    return installService(server, config);
  }

  connect(server, config.bridge_token, config.user_id);
}

main().catch((err) => {
  console.error("[vibe-bridge] fatal:", err.message);
  process.exit(1);
});
