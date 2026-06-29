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
const BRIDGE_INSTRUCTION_DIR = path.join(".vibe", "instructions");
const BRIDGE_INSTRUCTION_FILES = {
  "AGENTS.md": `# Vibe Agent Operating Guide

These rules apply to AI agents working through Vibe, including Claude and Codex.

## Role

- Act like a senior engineer working in a real production codebase.
- Inspect the existing code before proposing or editing.
- Prefer the repository's existing architecture, naming, and UI patterns.
- Keep changes scoped to the user's request.
- Do not perform unrelated refactors or cleanup.

## Local Bridge Workflow

- The selected project lives on the user's computer, not on the phone.
- Treat the mobile app as the control surface for prompts, command approvals, progress, files, diffs, and results.
- Surface useful runtime details: commands, files touched, patches, blockers, verification, and remaining risk.
- If a command needs approval, explain the exact command, why it is needed, and the risk.

## Claude and Codex Teamwork

- When a task includes both Claude and Codex, work as one team.
- Do not duplicate another agent's likely work.
- If the user assigns work by name, follow that assignment exactly.
- If work is not assigned, choose a non-overlapping slice and state what you took.
- Read teammate notes before continuing.
- Use .vibe/team/<team_run_id>.md as the shared handoff file when repo writes are allowed.
- Keep handoff edits additive under your own section with ownership, findings, files changed, blockers, and next steps.

## Browser, Chrome, and Agent Browser Work

- When the user mentions Chrome, browser testing, screenshots, clicking UI, or Agent Browser, use the browser automation tools/CLI available on this computer instead of guessing.
- Prefer the repo's existing dev-server/test scripts, then verify with browser automation: open the page, inspect visible UI, check console/runtime errors, click the important controls, and capture screenshots when useful.
- Report the URL, what was verified, and any browser/tool blocker in the final result.

## Safety

- Start with read-only inspection when the risk is unclear.
- Do not delete files, reset git state, force push, rotate secrets, or run destructive commands unless the user explicitly approves.
- Never expose secrets, tokens, private keys, or local credentials.
- Do not overwrite user work. Check the current diff before touching files that may already be edited.

## Implementation Standard

- Make the smallest complete change that solves the real problem.
- Prefer structured payloads over flattened text when the app needs to render tools, commands, patches, or runtime state.
- For iOS work, keep UI behavior consistent with the existing SwiftUI/UIKit patterns.
- For server work, preserve auth boundaries, group ownership, and per-user bridge routing.
- For bridge work, keep repo selection, work mode, provider, command status, and task metadata visible.

## Done Criteria

- State what changed.
- State what was tested.
- State whether the result was source-verified, build-verified, bridge-verified, mobile-verified, or live-verified.
- Call out any remaining risk or manual validation that is still needed.
`,
  "CLAUDE.md": `# Claude Instructions

Follow AGENTS.md first. These additions are specific to Claude.

- Use planning and code review strengths to identify risks, architecture boundaries, and missing verification.
- When paired with Codex, avoid doing the same implementation slice unless the user asks for a second opinion.
- Write concise handoff notes in .vibe/team/<team_run_id>.md so Codex can continue without rereading everything.
- If the task is not safe to edit yet, explain the blocker and the exact inspection or approval needed.
- If the user mentions Agent Browser, Chrome, or browser automation, use the local browser automation path when available and report if Claude cannot access it in this session.
`,
  "CODEX.md": `# Codex Instructions

Follow AGENTS.md first. These additions are specific to Codex.

- Use implementation and verification strengths to make focused patches and run the relevant checks.
- When paired with Claude, read Claude's handoff before editing and take the next non-overlapping implementation slice.
- Keep command output and patch summaries structured enough for Vibe to render progress, files changed, and verification.
- If a command or edit is risky, stop and ask for explicit approval through Vibe.
`,
};

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

// Decrypt an `arte1.<iv>.<ct>.<tag>` blob the phone sealed with the shared pairing
// key (e.g. an image attachment). Returns the parsed object, or null when there's no
// key, the envelope is malformed, or authentication fails.
function decryptRuntimeBlob(blob) {
  if (!RUNTIME_KEY_B64 || typeof blob !== "string") return null;
  const parts = blob.split(".");
  if (parts.length !== 4 || parts[0] !== RUNTIME_BLOB_PREFIX) return null;
  try {
    const key = Buffer.from(RUNTIME_KEY_B64, "base64");
    if (key.length !== 32) return null;
    const iv = Buffer.from(parts[1], "base64url");
    const ct = Buffer.from(parts[2], "base64url");
    const tag = Buffer.from(parts[3], "base64url");
    const decipher = crypto.createDecipheriv("aes-256-gcm", key, iv);
    decipher.setAuthTag(tag);
    const pt = Buffer.concat([decipher.update(ct), decipher.final()]);
    return JSON.parse(pt.toString("utf8"));
  } catch (err) {
    console.error("[vibe-bridge] attachment decrypt failed:", err.message);
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

function bridgeInstructionRelativeFiles(provider) {
  const files = [path.join(BRIDGE_INSTRUCTION_DIR, "AGENTS.md")];
  if (provider === "claude") files.push(path.join(BRIDGE_INSTRUCTION_DIR, "CLAUDE.md"));
  else if (provider === "codex") files.push(path.join(BRIDGE_INSTRUCTION_DIR, "CODEX.md"));
  else {
    files.push(path.join(BRIDGE_INSTRUCTION_DIR, "CLAUDE.md"));
    files.push(path.join(BRIDGE_INSTRUCTION_DIR, "CODEX.md"));
  }
  return files;
}

function ensureBridgeInstructionFiles(repo) {
  const root = repo && (repo.cwd || repo.path);
  if (!root) return [];

  const dir = path.join(root, BRIDGE_INSTRUCTION_DIR);
  const written = [];

  try {
    fs.mkdirSync(dir, { recursive: true });
    ensureBridgeInstructionGitExclude(root);

    for (const [name, content] of Object.entries(BRIDGE_INSTRUCTION_FILES)) {
      const absolutePath = path.join(dir, name);
      if (!fs.existsSync(absolutePath) || fs.readFileSync(absolutePath, "utf8") !== content) {
        fs.writeFileSync(absolutePath, content, "utf8");
      }
      written.push({
        name,
        path: path.join(BRIDGE_INSTRUCTION_DIR, name),
        absolutePath,
      });
    }

    repo.instructionFiles = written;
    repo.instructionsReady = true;
    return written;
  } catch (err) {
    repo.instructionFiles = written;
    repo.instructionsReady = false;
    repo.instructionsError = err && err.message ? err.message : String(err);
    console.error(`[vibe-bridge] could not write instruction files for ${root}: ${repo.instructionsError}`);
    return written;
  }
}

function ensureVibeGitExclude(root, marker) {
  const gitDir = path.join(root, ".git");
  try {
    if (!fs.existsSync(gitDir) || !fs.statSync(gitDir).isDirectory()) return;
    const excludePath = path.join(gitDir, "info", "exclude");
    fs.mkdirSync(path.dirname(excludePath), { recursive: true });
    const current = fs.existsSync(excludePath) ? fs.readFileSync(excludePath, "utf8") : "";
    if (!current.split(/\r?\n/).some((line) => line.trim() === marker)) {
      fs.appendFileSync(excludePath, `${current.endsWith("\n") || current.length === 0 ? "" : "\n"}${marker}\n`);
    }
  } catch (_) {}
}

function ensureBridgeInstructionGitExclude(root) {
  ensureVibeGitExclude(root, ".vibe/instructions/");
}

function ensureBridgeInstructionsForRepositories(repositories) {
  for (const repo of repositories || []) ensureBridgeInstructionFiles(repo);
}

// The heavy "read AGENTS.md/CLAUDE.md + use the team handoff file" preamble is only
// appropriate for real engineering / team work — injecting it on every casual DM
// message made the agent eagerly go read the repo + team files for a plain "hi".
// Gate it: inject only for team runs or when the user explicitly @mentions an
// agent/team. A plain DM message gets just the user's prompt.
function taskWantsBridgeInstructions(task, prompt) {
  if (task) {
    if (task.teamMode || task.team_mode || task.teamRunId || task.team_run_id) return true;
    if (Array.isArray(task.teamWorkers) && task.teamWorkers.length) return true;
    if (Array.isArray(task.teamWorker) && task.teamWorker.length) return true;
  }
  return /(^|\s)@(codex|claude|team|vibe)\b/i.test(String(prompt || ""));
}

function taskPromptWithBridgeInstructions(provider, prompt, repo) {
  const cleaned = stripReservedMention(prompt, provider);
  const ready = ensureBridgeInstructionFiles(repo);
  const readyNames = new Set(ready.map((file) => file.path));
  const fileLines = bridgeInstructionRelativeFiles(provider)
    .map((file) => `- ${file}${readyNames.has(file) ? "" : " (write failed; follow inline rules instead)"}`)
    .join("\n");

  return `Vibe bridge startup prepared these instruction files for this project:
${fileLines}

Before acting, read and follow those files when available. If they are unavailable, follow the same rules from the Vibe bridge prompt: inspect first, keep changes scoped, avoid duplicate teammate work, ask before risky commands, report files changed, verification, blockers, and remaining risk.

User task:
${cleaned}`;
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
const finishedTasks = new Map(); // taskKey -> { provider, chatId, taskId, repo, runtime, finishedAt, resultPayload }
// Resilience state for surviving a dropped socket (code=1006 idle/proxy, 1012 server
// restart) WITHOUT losing a turn. `socketDownSince` is the epoch ms of the drop (null
// while connected); on rejoin we re-deliver any result that completed during the outage
// (its one-shot push was lost) and re-establish history watches so the phone re-syncs
// instead of showing a stale "connected" / needing an app restart.
let socketDownSince = null;
const historyWatchSpecs = new Map(); // chatId -> { provider, sessionId, echo } (survives reconnect)
const modelBySession = new Map(); // provider:chatId -> model selected from mobile
const lastRuntimeBySession = new Map(); // provider:chatId -> last completed runtime payload
const capabilitiesByProvider = new Map(); // provider -> latest tools/slash/MCP metadata

const BRIDGE_COMMANDS = [
  "/commands",
  "/help",
  "/usage",
  "/skills",
  "/model [name|default]",
  "/compact",
  "/status",
  "/doctor",
];

// Slash-command catalogs surfaced in the phone `/` palette and described by /help and
// /commands. `kind` records how the bridge handles each when sent from the phone:
//   bridge  — the bridge synthesizes real output locally (no agent turn, no token cost).
//   task    — passes through to the CLI and runs as a normal agent turn. PROVEN for
//             Claude: `claude -p` parses slash commands; skills/workflows/built-ins run,
//             and an interactive-only one returns a $0 "isn't available in this
//             environment" notice (so passthrough is safe).
//   option  — sets a run option for the NEXT send (model / effort / plan mode).
//   desktop — interactive-only in the terminal / desktop app. Codex slash commands are
//             ALL TUI-only: `codex exec` treats "/foo" as literal prompt text (verified),
//             so they cannot run headless from the phone — listed for discovery + handled
//             by the bridge where an equivalent exists.
// The authoritative live Claude list comes from each run's stream-json `init.slash_commands`
// (see providerMetadataFromOutput); these defaults seed the palette before the first run.
const CLAUDE_SLASH_INFO = [
  { name: "code-review", desc: "Review the current diff for bugs and cleanups", kind: "task" },
  { name: "simplify", desc: "Cleanup-only review; apply simplifications", kind: "task" },
  { name: "security-review", desc: "Scan pending changes for security issues", kind: "task" },
  { name: "review", desc: "Review a GitHub pull request", kind: "task" },
  { name: "batch", desc: "Split a large change into parallel units", kind: "task" },
  { name: "deep-research", desc: "Fan out web research into a cited report", kind: "task" },
  { name: "claude-api", desc: "Load Claude API reference for this project", kind: "task" },
  { name: "debug", desc: "Troubleshoot using the session debug log", kind: "task" },
  { name: "run", desc: "Launch and drive your app to see a change work", kind: "task" },
  { name: "verify", desc: "Build, run, and observe to confirm a change", kind: "task" },
  { name: "loop", desc: "Run a prompt repeatedly across iterations", kind: "task" },
  { name: "schedule", desc: "Create or run a scheduled cloud routine", kind: "task" },
  { name: "team-onboarding", desc: "Generate a team onboarding guide", kind: "task" },
  { name: "fewer-permission-prompts", desc: "Add a read-only allowlist to settings", kind: "task" },
  { name: "init", desc: "Generate a CLAUDE.md project guide", kind: "task" },
  { name: "insights", desc: "Analyze your recent Claude Code sessions", kind: "task" },
  { name: "goal", desc: "Keep working across turns until a goal is met", kind: "task" },
  { name: "context", desc: "Show context-window usage", kind: "task" },
  { name: "config", desc: "View or set a setting (key=value)", kind: "task" },
  { name: "skills", desc: "Browse and use skills", kind: "bridge" },
  { name: "clear", desc: "Start a fresh conversation (new task)", kind: "task" },
  { name: "compact", desc: "Drop the resumed session for the next run", kind: "bridge" },
  { name: "usage", desc: "Plan limits + this chat's token/cost usage", kind: "bridge" },
  { name: "usage-credits", desc: "Configure extra usage credits", kind: "task" },
  { name: "status", desc: "Account, model, and remaining usage", kind: "bridge" },
  { name: "doctor", desc: "Diagnose the Claude Code install", kind: "bridge" },
  { name: "model", desc: "Show or switch the model", kind: "bridge" },
  { name: "plan", desc: "Plan mode: research & propose, don't edit", kind: "option" },
  { name: "help", desc: "List bridge, slash, and CLI commands", kind: "bridge" },
];

const CODEX_SLASH_INFO = [
  { name: "review", desc: "Ask Codex to review your working tree", kind: "desktop" },
  { name: "plan", desc: "Plan mode: research & propose, don't edit", kind: "option" },
  { name: "model", desc: "Show or switch the model", kind: "bridge" },
  { name: "approvals", desc: "Set what Codex can do without asking", kind: "desktop" },
  { name: "status", desc: "Account, model, and remaining usage", kind: "bridge" },
  { name: "usage", desc: "View account token usage", kind: "bridge" },
  { name: "diff", desc: "Show the working-tree git diff", kind: "desktop" },
  { name: "compact", desc: "Summarize the conversation to free tokens", kind: "bridge" },
  { name: "new", desc: "Start a new conversation", kind: "desktop" },
  { name: "clear", desc: "Clear and start a fresh chat", kind: "desktop" },
  { name: "init", desc: "Generate an AGENTS.md scaffold", kind: "desktop" },
  { name: "skills", desc: "Browse and use skills", kind: "desktop" },
  { name: "agent", desc: "Switch the active agent thread", kind: "desktop" },
  { name: "apps", desc: "Browse connectors and insert them", kind: "desktop" },
  { name: "plugins", desc: "Browse installed and discoverable plugins", kind: "desktop" },
  { name: "mcp", desc: "List configured MCP tools", kind: "desktop" },
  { name: "mention", desc: "Attach a file to the conversation", kind: "desktop" },
  { name: "fork", desc: "Fork the conversation into a new thread", kind: "desktop" },
  { name: "resume", desc: "Resume a saved conversation", kind: "desktop" },
  { name: "memories", desc: "Configure memory use and generation", kind: "desktop" },
  { name: "goal", desc: "Set or view a task goal", kind: "desktop" },
  { name: "fast", desc: "Toggle the Fast service tier", kind: "option" },
  { name: "personality", desc: "Choose a response communication style", kind: "desktop" },
  { name: "doctor", desc: "Diagnose the Codex install", kind: "bridge" },
  { name: "logout", desc: "Sign out of Codex", kind: "desktop" },
  { name: "help", desc: "List bridge, slash, and CLI commands", kind: "bridge" },
];

// Wire catalog sent to the phone palette: every command except the /help & /commands
// meta entries. Includes run-option (/plan, /fast) and bridge-answered ones so the
// palette is complete; iOS dedupes them against its built-in defaults.
const slashNamesFromInfo = (info) => info.filter((c) => c.name !== "help" && c.name !== "commands").map((c) => c.name);

const DEFAULT_CLAUDE_SLASH_COMMANDS = slashNamesFromInfo(CLAUDE_SLASH_INFO);
const DEFAULT_CODEX_SLASH_COMMANDS = slashNamesFromInfo(CODEX_SLASH_INFO);

// Terminal subcommands visible on this computer (display-only in /commands and /help).
const DEFAULT_CLAUDE_CLI_COMMANDS = [
  "agents",
  "config",
  "doctor",
  "mcp",
  "plugin",
  "update",
  "login",
  "logout",
];

const DEFAULT_CODEX_CLI_COMMANDS = [
  "exec",
  "review",
  "login",
  "logout",
  "mcp",
  "plugin",
  "doctor",
  "apply",
  "resume",
  "fork",
  "cloud",
  "sandbox",
  "update",
];

// name -> one-line description for the bridge-rendered /help and /commands text.
const CLAUDE_COMMAND_DESC = Object.fromEntries(CLAUDE_SLASH_INFO.map((c) => [c.name, c.desc]));
const CODEX_COMMAND_DESC = Object.fromEntries(CODEX_SLASH_INFO.map((c) => [c.name, c.desc]));
const CLAUDE_DESKTOP_ONLY = new Set(CLAUDE_SLASH_INFO.filter((c) => c.kind === "desktop").map((c) => c.name));
const CODEX_DESKTOP_ONLY = new Set(CODEX_SLASH_INFO.filter((c) => c.kind === "desktop").map((c) => c.name));

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
    case "ask_auto":
      return "auto";
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
    case "ask_auto":
      return "workspace-write";
    case "allow_edits":
      return "workspace-write";
    default:
      return "read-only";
  }
}

function codexApprovalPolicy(task) {
  if (process.env.VIBE_CODEX_APPROVAL_POLICY) return process.env.VIBE_CODEX_APPROVAL_POLICY;
  switch (workModeFor(task)) {
    case "full_access":
    case "ask_auto":
    case "allow_edits":
      return "never";
    case "ask":
      return "on-request";
    default:
      return "untrusted";
  }
}

const DEFAULT_CLAUDE_MOBILE_DISALLOWED_TOOLS = [
  "Bash(git push*)",
  "Bash(git checkout*)",
  "Bash(git reset*)",
  "Bash(git clean*)",
  "Bash(rm -rf*)",
  "Bash(rm -r*)",
  "Bash(sudo *)",
  "Bash(chmod -R*)",
  "Bash(chown -R*)",
  "Bash(security *)",
  "Bash(defaults write*)",
  "Bash(killall *)",
];

function claudeDisallowedTools(task) {
  const override = splitEnvList(process.env.VIBE_CLAUDE_DISALLOWED_TOOLS);
  if (override.length) return override;
  // Full access means the user explicitly asked for bypass behavior. All other
  // mobile modes keep destructive commands on the ask/block side while Claude's
  // own `auto` classifier can run low-risk inspection/build commands.
  if (workModeFor(task) === "full_access") return [];
  return DEFAULT_CLAUDE_MOBILE_DISALLOWED_TOOLS;
}

function appendToolListArg(args, flag, values) {
  const list = compactStringList(values || [], 80);
  if (!list.length) return;
  args.push(flag, list.join(","));
}

function normalizeModel(provider, value) {
  const raw = value == null ? "" : String(value).trim();
  if (!raw) return null;
  const normalized = raw.toLowerCase().replace(/_/g, "-");
  if (provider === "claude") {
    if (normalized.includes("haiku")) return "haiku";
    if (normalized.includes("sonnet")) return "sonnet";
    if (normalized.includes("opus")) return "opus";
    return raw;
  }
  if (normalized === "gpt-5.3-codex" || normalized === "gpt-5-3-codex") return "gpt-5.5";
  if (["gpt-5.5", "gpt-5.5-pro", "gpt-5.4", "gpt-5.2", "gpt-5"].includes(normalized)) {
    return normalized;
  }
  return raw;
}

function modelFor(provider, chatId, task) {
  const requested = task && (task.model || task.agentModel || task.agentBridgeModel);
  if (requested && String(requested).trim()) return normalizeModel(provider, requested);
  const stored = modelBySession.get(sessionKey(provider, chatId));
  if (stored && String(stored).trim()) return normalizeModel(provider, stored);
  const envModel = provider === "claude" ? process.env.VIBE_CLAUDE_MODEL : process.env.VIBE_CODEX_MODEL;
  return envModel && String(envModel).trim() ? normalizeModel(provider, envModel) : null;
}

function intelligenceFor(task) {
  const raw = String(
    (task && (task.intelligence || task.agentBridgeIntelligence || task.thinkingMode)) || "low"
  )
    .trim()
    .toLowerCase()
    .replace(/[\s-]+/g, "_");
  if (["extra_high", "xhigh", "extra", "max"].includes(raw)) return "extra_high";
  if (["high"].includes(raw)) return "high";
  if (["medium", "med", "standard"].includes(raw)) return "medium";
  return "low";
}

function speedFor(task) {
  const raw = String((task && (task.speed || task.agentBridgeSpeed || task.speedMode)) || "standard")
    .trim()
    .toLowerCase()
    .replace(/[\s-]+/g, "_");
  if (["fast", "quick", "low_latency"].includes(raw)) return "fast";
  if (["careful", "thorough", "deep", "slow"].includes(raw)) return "careful";
  return "standard";
}

function requestedReasoningEffortFor(task) {
  const raw =
    task &&
    (task.reasoningEffort ||
      task.agentBridgeReasoningEffort ||
      task.effort ||
      task.agentBridgeEffort);
  if (!raw) return null;
  const normalized = String(raw).trim().toLowerCase().replace(/[\s-]+/g, "_");
  if (["xhigh", "extra_high", "max"].includes(normalized)) return "xhigh";
  if (["high", "medium", "low"].includes(normalized)) return normalized;
  return null;
}

function reasoningEffortFor(provider, task) {
  const requested = requestedReasoningEffortFor(task);
  const ladder = provider === "claude" ? ["low", "medium", "high", "xhigh"] : ["low", "medium", "high"];
  if (requested) {
    if (ladder.includes(requested)) return requested;
    if (requested === "xhigh") return "high";
  }

  const intelligence = intelligenceFor(task);
  const speed = speedFor(task);
  const base =
    intelligence === "extra_high"
      ? provider === "claude"
        ? "xhigh"
        : "high"
      : intelligence;
  const baseIndex = Math.max(0, ladder.indexOf(base));
  const offset = speed === "fast" ? -1 : speed === "careful" ? 1 : 0;
  return ladder[Math.min(Math.max(baseIndex + offset, 0), ladder.length - 1)];
}

function buildCommand(provider, prompt, chatId, task) {
  const cleaned = stripReservedMention(prompt, provider);
  const model = modelFor(provider, chatId, task);
  if (provider === "claude") {
    const mode = claudePermissionMode(task);
    const effort = reasoningEffortFor(provider, task);
    const args = ["-p", "--output-format", "stream-json", "--permission-mode", mode, "--effort", effort];
    appendToolListArg(args, "--disallowedTools", claudeDisallowedTools(task));
    const resumeId = resumeIdFor(task);
    if (resumeId) args.push("--resume", resumeId);
    args.push("--verbose");
    if (model) args.push("--model", model);
    args.push("--", cleaned);
    return { cmd: process.env.VIBE_CLAUDE_COMMAND || "claude", args };
  }
  if (provider === "codex") {
    const sandbox = codexSandbox(task);
    const approvalPolicy = codexApprovalPolicy(task);
    const resumeId = resumeIdFor(task);
    const reasoning = reasoningEffortFor(provider, task);
    // `codex exec resume <thread-id>` continues a prior thread; a bare `codex exec`
    // starts fresh. The `resume` subcommand REJECTS the exec-only flags
    // `--sandbox`/`--model`/`--skip-git-repo-check` (its usage is
    // `codex exec resume --json <SESSION_ID> [PROMPT]`), so passing them on resume
    // failed with `error: unexpected argument '--sandbox'` (exit 2). Run config is
    // therefore passed via `-c` overrides, which are global options accepted on both
    // `codex exec` and `codex exec resume`. Options precede the positional
    // SESSION_ID/PROMPT so clap doesn't mistake them for positionals.
    const args = ["exec"];
    if (resumeId) args.push("resume");
    args.push("--json");
    args.push("-c", `sandbox_mode="${sandbox}"`);
    args.push("-c", `approval_policy="${approvalPolicy}"`);
    if (model) args.push("-c", `model="${model}"`);
    args.push("-c", `model_reasoning_effort="${reasoning}"`);
    if (!resumeId) {
      // Fresh runs only: exec-specific flags the resume subcommand doesn't accept.
      // Ephemeral runs leave nothing to resume, so they're never used on resume.
      args.push("--skip-git-repo-check", "--ephemeral");
    }
    if (resumeId) args.push(resumeId);
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
      : compactStringList(metadata.slashCommands || DEFAULT_CODEX_SLASH_COMMANDS, 80),
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
    metadata.slashCommands = DEFAULT_CODEX_SLASH_COMMANDS;
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

// Bridge-intercepted slash commands answered locally (real data, no agent turn).
const BRIDGE_INTERCEPT_COMMANDS = ["commands", "help", "usage", "skills", "model", "compact", "status", "doctor"];

function parseBridgeCommand(prompt, provider) {
  const text = String(prompt || "").trim();
  if (!text.startsWith("/")) return null;
  const firstLine = text.split(/\r?\n/, 1)[0].trim();
  const match = firstLine.match(/^\/([a-z][a-z0-9_-]*)(?:\s+(.*))?$/i);
  if (!match) return null;
  const name = match[1].toLowerCase();
  const base = { name, args: (match[2] || "").trim(), raw: firstLine };
  if (BRIDGE_INTERCEPT_COMMANDS.includes(name)) return base;
  // Codex slash commands are TUI-only — `codex exec` would treat "/foo" as literal
  // prompt text and waste a turn. Intercept its known desktop-only commands and answer
  // with a helpful note instead of spawning. (Claude DOES parse slash commands headless,
  // so anything else falls through to the CLI on purpose for Claude.)
  if (provider === "codex" && CODEX_DESKTOP_ONLY.has(name)) {
    return { ...base, desktopOnly: true };
  }
  return null;
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
  const title = provider === "claude" ? "Claude" : provider === "codex" ? "Codex" : provider;
  const descOf = provider === "claude" ? CLAUDE_COMMAND_DESC : CODEX_COMMAND_DESC;
  const desktopOnly = provider === "claude" ? CLAUDE_DESKTOP_ONLY : CODEX_DESKTOP_ONLY;
  const slashLine = (cmd) => {
    const desc = descOf[cmd];
    const flag = desktopOnly.has(cmd) ? " (desktop only)" : "";
    return desc ? `- /${cmd} — ${desc}${flag}` : `- /${cmd}${flag}`;
  };
  const lines = [
    "Bridge commands (answered right here, no agent run):",
    ...catalog.bridge.map((cmd) => `- ${cmd}`),
    "",
  ];
  const slashToShow = catalog.slash.filter((cmd) => !BRIDGE_INTERCEPT_COMMANDS.includes(cmd));
  if (slashToShow.length) {
    lines.push(`${title} slash commands — type / in the message box:`);
    lines.push(...slashToShow.map(slashLine));
    if (provider === "claude") {
      lines.push("Sending one runs it as an agent turn; interactive-only ones reply that they need the desktop.");
    } else {
      lines.push("Codex slash commands run in the desktop/terminal app; from the phone the bridge answers the ones it can.");
    }
    lines.push("");
  }
  if (catalog.cli.length) {
    lines.push(`${title} terminal subcommands on this computer:`);
    lines.push(...catalog.cli.map((cmd) => `- ${title.toLowerCase()} ${cmd}`));
  }
  return lines.join("\n").trim();
}

function formatSkills(provider) {
  const caps = capabilitiesByProvider.get(provider) || {};
  const title = provider === "claude" ? "Claude" : provider === "codex" ? "Codex" : provider;
  const sections = [];
  const addList = (label, values) => {
    const list = compactStringList(values || [], 80);
    if (!list.length) return;
    sections.push(`${label}:\n${list.map((item) => `- ${item}`).join("\n")}`);
  };
  addList("Skills", caps.skills);
  addList("Agents", caps.agents);
  addList("Tools", caps.availableTools);
  const mcp = Array.isArray(caps.mcpServers) ? caps.mcpServers : [];
  if (mcp.length) {
    sections.push(
      "MCP servers:\n" +
        mcp
          .map((server) => {
            const name = server && server.name ? String(server.name) : "";
            const status = server && server.status ? String(server.status) : "";
            return name ? `- ${name}${status ? ` (${status})` : ""}` : null;
          })
          .filter(Boolean)
          .join("\n")
    );
  }
  if (sections.length) return `${title} capabilities\n\n${sections.join("\n\n")}`;
  return [
    `${title} capabilities`,
    "No skills, agents, MCP servers, or tool list has been reported for this chat yet.",
    "Run one agent task first so the bridge can capture the provider init metadata.",
  ].join("\n");
}

// Run a short, read-only provider subcommand and capture its output. Used to make
// /status and /doctor reflect what the REAL CLI reports (account, health) instead
// of a locally-synthesized placeholder. Bounded time + output; never throws.
function runCliCapture(cmd, args, timeoutMs = 12000) {
  try {
    const out = execFileSync(cmd, args, {
      encoding: "utf8",
      timeout: timeoutMs,
      maxBuffer: 256 * 1024,
      stdio: ["ignore", "pipe", "pipe"],
    });
    return String(out || "").trim();
  } catch (err) {
    const partial = String((err && (err.stdout || err.stderr)) || "").trim();
    return partial || null;
  }
}

// Real account/login status from the provider CLI. Codex exposes `codex login
// status`; Claude has no headless account command, so we return null and let the
// caller fall back to the model/usage context it already has.
function providerAccountStatus(provider) {
  if (provider === "codex") {
    return runCliCapture("codex", ["login", "status"], 8000) || "Codex login status unavailable.";
  }
  return null;
}

// REAL Claude subscription usage. The interactive `/usage` view fetches this from
// `GET /api/oauth/usage` (the CLI's `fetchUtilization`) using the same OAuth token
// the `claude` CLI stores in the macOS Keychain. We read that token and call the
// endpoint ourselves so the phone's /usage shows the actual 5-hour + 7-day limits
// (utilization % + reset time), not a locally-synthesized placeholder. Cached
// briefly so repeated taps don't hammer the endpoint. Returns null on any failure
// (no token / expired / offline) — callers fall back to per-run token counts.
let claudeUtilCache = { at: 0, data: null };
async function fetchClaudeUtilization() {
  if (claudeUtilCache.data && Date.now() - claudeUtilCache.at < 45000) return claudeUtilCache.data;
  let token = null;
  try {
    const raw = execFileSync(
      "security",
      ["find-generic-password", "-s", "Claude Code-credentials", "-w"],
      { encoding: "utf8", timeout: 5000, stdio: ["ignore", "pipe", "ignore"] }
    );
    const parsed = JSON.parse(raw);
    token = parsed && parsed.claudeAiOauth && parsed.claudeAiOauth.accessToken;
  } catch (_) {
    token = null;
  }
  if (!token) return null;
  try {
    const res = await fetch("https://api.anthropic.com/api/oauth/usage", {
      headers: { Authorization: `Bearer ${token}`, "anthropic-beta": "oauth-2025-04-20" },
      signal: AbortSignal.timeout(10000),
    });
    if (!res.ok) return null;
    const data = await res.json();
    claudeUtilCache = { at: Date.now(), data };
    return data;
  } catch (_) {
    return null;
  }
}

function fmtResetIn(iso) {
  const t = Date.parse(iso || "");
  if (!Number.isFinite(t)) return "";
  const ms = t - Date.now();
  if (ms <= 0) return "resetting now";
  const h = Math.floor(ms / 3600000);
  const m = Math.floor((ms % 3600000) / 60000);
  if (h >= 24) return `resets in ${Math.floor(h / 24)}d ${h % 24}h`;
  if (h >= 1) return `resets in ${h}h ${m}m`;
  return `resets in ${m}m`;
}

function formatClaudeUtilization(util) {
  if (!util || typeof util !== "object") return null;
  const lines = [];
  const bucket = (label, b) => {
    if (!b || typeof b !== "object" || b.utilization == null) return;
    const reset = fmtResetIn(b.resets_at);
    lines.push(`${label}: ${Math.round(Number(b.utilization))}% used${reset ? ` · ${reset}` : ""}`);
  };
  bucket("5-hour session", util.five_hour);
  bucket("7-day (all models)", util.seven_day);
  bucket("7-day Opus", util.seven_day_opus);
  bucket("7-day Sonnet", util.seven_day_sonnet);
  return lines.length ? lines.join("\n") : null;
}

async function bridgeCommandOutput(provider, chatId, task, repo, command) {
  const key = sessionKey(provider, chatId);
  const currentModel = modelFor(provider, chatId, task);
  const lastRuntime = lastRuntimeBySession.get(key);
  const providerTitle = provider === "claude" ? "Claude" : provider === "codex" ? "Codex" : provider;
  if (command.desktopOnly) {
    const desc = (provider === "claude" ? CLAUDE_COMMAND_DESC : CODEX_COMMAND_DESC)[command.name];
    return [
      `/${command.name}${desc ? ` — ${desc}` : ""}`,
      `This is an interactive ${providerTitle} command that runs in the desktop/terminal app, so it can't run headless from the phone.`,
      "Send it from the Codex app on your computer, or just describe what you want and I'll do it as a normal request.",
    ].join("\n");
  }
  switch (command.name) {
    case "commands":
    case "help":
      return formatCommands(provider);
    case "skills":
      return formatSkills(provider);
    case "usage": {
      const lines = [`${providerTitle} usage`];
      if (provider === "claude") {
        const util = formatClaudeUtilization(await fetchClaudeUtilization());
        if (util) {
          lines.push("Subscription limits:");
          lines.push(util);
          lines.push("");
        } else {
          lines.push("(Subscription limits unavailable — sign in to Claude on this computer.)");
          lines.push("");
        }
      }
      lines.push("This chat (last run):");
      lines.push(formatUsage(lastRuntime));
      lines.push(currentModel ? `Model: ${currentModel}` : "Model: provider default");
      return lines.join("\n");
    }
    case "model": {
      const next = command.args.trim();
      if (!next) return `Current ${provider} model: ${currentModel || "provider default"}`;
      if (["default", "reset", "auto"].includes(next.toLowerCase())) {
        modelBySession.delete(key);
        return `${provider} model reset to provider default for this chat.`;
      }
      const normalizedModel = normalizeModel(provider, next);
      modelBySession.set(key, normalizedModel);
      return `${provider} model set to ${normalizedModel} for this chat.`;
    }
    case "compact":
      sessionByChat.delete(chatId);
      return [
        "Bridge context compacted for this chat.",
        "The next Claude request will start without the previous --resume session.",
        "Codex bridge runs are already ephemeral in this noninteractive path.",
      ].join("\n");
    case "doctor": {
      const out = runCliCapture(provider === "codex" ? "codex" : "claude", ["doctor"], 25000);
      return out || `${providerTitle} doctor produced no output.`;
    }
    case "status": {
      // What the user actually wants from /status: their ACCOUNT + remaining usage,
      // not the bridge connection. Lead with the real login/subscription status and
      // (for Claude) the live 5h/7d limits, then the run context.
      const lines = [`${providerTitle} status`];
      const account = providerAccountStatus(provider);
      if (account) lines.push(account);
      if (provider === "claude") {
        const util = formatClaudeUtilization(await fetchClaudeUtilization());
        if (util) lines.push(util);
      }
      lines.push(`model: ${currentModel || "provider default"}`);
      lines.push(`usage (last run): ${formatUsage(lastRuntime)}`);
      lines.push(`repo: ${repo.name} · mode: ${workModeFor(task)}`);
      return lines.join("\n");
    }
    default:
      return null;
  }
}

async function runBridgeCommand(channel, task, repo, beforeGit, command) {
  const { provider, chatId, replyToId, requesterUserId } = task;
  const taskId = taskIdFor(task || {});
  const startedAt = Date.now();
  const output = await bridgeCommandOutput(provider, chatId, task, repo, command);
  if (output == null) return false;
  const lastRuntime = lastRuntimeBySession.get(sessionKey(provider, chatId));

  channel.push("progress", {
    provider,
    chatId,
    taskId,
    sequence: 1,
    sentAtMs: Date.now(),
    replyToId,
    repoId: repo.id,
    repoName: repo.name,
    cwd: repo.cwd || repo.path,
    workMode: workModeFor(task),
    model: modelFor(provider, chatId, task) || null,
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
  if ((command.name === "usage" || command.name === "status") && lastRuntime && lastRuntime.usage) {
    agentRuntime.usage = lastRuntime.usage;
  }
  agentRuntime.providerCommands = providerCommandCatalog(
    provider,
    capabilitiesByProvider.get(provider) || {}
  ).bridge;
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
    ...teamFieldsForTask(task),
    ...runtimeResultField(agentRuntime),
  });
  return true;
}

// The runtime card should reflect what THIS run changed, not the user's
// pre-existing uncommitted work. `after` is the full `git diff HEAD`, which
// includes files that were already dirty before the agent ran. Subtract every
// file that is unchanged since the pre-run snapshot so a no-op turn (e.g. a
// plain "Hi" that edits nothing) yields an EMPTY diff — which iOS renders as no
// files-changed card at all (parseAgentRuntimeSummary returns nil on 0 files).
function runAttributedDiff(cwd, before, after) {
  if (!after || !after.git) return after;
  // Clean repo before the run → everything in `after` is the agent's doing.
  if (!before || !before.dirty) return after;
  const beforeByPath = new Map();
  for (const f of before.files || []) beforeByPath.set(f.path, f);
  const files = (after.files || []).filter((f) => {
    const prev = beforeByPath.get(f.path);
    if (!prev) return true; // path first touched during this run
    return (
      (prev.additions || 0) !== (f.additions || 0) ||
      (prev.deletions || 0) !== (f.deletions || 0) ||
      (prev.status || "") !== (f.status || "")
    );
  });
  // Nothing pre-existing overlapped → keep the original (incl. its full patch).
  if (files.length === (after.files || []).length) return after;
  const additions = files.reduce((s, f) => s + (f.additions || 0), 0);
  const deletions = files.reduce((s, f) => s + (f.deletions || 0), 0);
  // Re-scope the patch to the attributed paths so the diff viewer matches the
  // card. Empty when the run changed nothing.
  let patch = "";
  let patchTruncated = false;
  if (files.length) {
    const tracked = files.filter((f) => f.status !== "A?").map((f) => f.path);
    const trackedPatch = tracked.length
      ? runGit(cwd, ["diff", "--no-ext-diff", "--unified=80", "HEAD", "--", ...tracked], MAX_DIFF_BYTES)
      : "";
    const newFiles = files.filter((f) => f.status === "A?");
    const remaining = Math.max(0, MAX_DIFF_BYTES - trackedPatch.length);
    const np = untrackedPatch(cwd, newFiles, remaining);
    patch = trackedPatch + np.patch;
    patchTruncated = patch.length >= MAX_DIFF_BYTES || np.truncated;
  }
  return { ...after, files, additions, deletions, patch, patchTruncated };
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
  const attributed = runAttributedDiff(repo.cwd || repo.path, before, after);
  const fileSummary =
    attributed && attributed.git ? attributed : { files: [], additions: 0, deletions: 0, patch: "" };
  const metadata = providerMetadataFromOutput(provider, output || "", task, task && task.chatId);
  const payload = {
    taskId,
    provider,
    status: canceled ? "stopped" : exitStatus === 0 ? "done" : "failed",
    repoId: repo.id,
    repoName: repo.name,
    cwd: repo.cwd || repo.path,
    workMode: workModeFor(task),
    ...teamFieldsForTask(task),
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

  const resolvedPayloadModel = metadata.model || modelFor(provider, task && task.chatId, task);
  if (resolvedPayloadModel) payload.model = resolvedPayloadModel;
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
	        approvalPolicy: process.env.VIBE_CODEX_APPROVAL_POLICY || "per-task",
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
    intelligence: entry.intelligence || null,
    speed: entry.speed || null,
    reasoningEffort: entry.reasoningEffort || null,
    startedAt: new Date(entry.startedAt).toISOString(),
    durationMs: Math.max(0, now - (entry.startedAt || now)),
    command: entry.command,
    pendingCommand: entry.command,
    teamMode: entry.teamMode || null,
    teamRunId: entry.teamRunId || null,
    teamWorker: entry.teamWorker || null,
    teamWorkers: Array.isArray(entry.teamWorkers) ? entry.teamWorkers : [],
  }));
}

function teamFieldsForTask(task) {
  if (!task || typeof task !== "object") {
    return { teamMode: null, teamRunId: null, teamWorker: null, teamWorkers: [] };
  }
  return {
    teamMode: task.teamMode || task.team_mode || null,
    teamRunId: task.teamRunId || task.team_run_id || null,
    teamWorker: task.teamWorker || task.team_worker || null,
    teamWorkers: Array.isArray(task.teamWorkers)
      ? task.teamWorkers
      : Array.isArray(task.team_workers)
        ? task.team_workers
        : [],
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
  ensureBridgeInstructionsForRepositories(ADVERTISED_REPOSITORIES);
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

// Decrypt the phone's sealed image attachments and write them under the repo's
// .vibe/attachments/ so the agent can Read them by path. Returns [{ path, name }].
// Files are git-excluded and cleaned up when the task finishes.
function materializeAttachments(task, cwd) {
  const blobs = Array.isArray(task.attachmentsEnc)
    ? task.attachmentsEnc
    : Array.isArray(task.agentBridgeAttachmentsEnc)
      ? task.agentBridgeAttachmentsEnc
      : [];
  if (!blobs.length) return [];
  const dir = path.join(cwd, ".vibe", "attachments");
  try {
    fs.mkdirSync(dir, { recursive: true });
    ensureVibeGitExclude(cwd, ".vibe/attachments/");
  } catch (_) {
    return [];
  }
  const written = [];
  for (const blob of blobs) {
    const obj = decryptRuntimeBlob(blob);
    if (!obj || typeof obj.dataB64 !== "string") continue;
    const ext = obj.mime === "image/png" ? "png" : "jpg";
    const filename = `${Date.now()}-${crypto.randomBytes(4).toString("hex")}.${ext}`;
    const absolutePath = path.join(dir, filename);
    try {
      fs.writeFileSync(absolutePath, Buffer.from(obj.dataB64, "base64"), { mode: 0o600 });
      written.push({
        path: absolutePath,
        name: typeof obj.name === "string" && obj.name ? obj.name : filename,
      });
    } catch (_) {}
  }
  return written;
}

async function runTask(channel, task) {
  const recvAt = Date.now();
  const { provider, chatId, prompt, replyToId, requesterUserId } = task;
  const taskId = taskIdFor(task || {});
  console.log(
    `[vibe-bridge] run_task received provider=${provider} chat=${chatId} ` +
      `task=${taskId} ` +
      `repoId=${task.repoId || task.agentBridgeRepoId || "-"} ` +
      `workMode=${task.workMode || task.agentBridgeWorkMode || "-"} promptLen=${(prompt || "").length}`
  );

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
  console.log(
    `[vibe-bridge] latency gitSnapshot(before)=${Date.now() - startedAt}ms ` +
      `chat=${chatId} task=${taskId} cwd=${cwd}`
  );
  const bridgeCommand = parseBridgeCommand(prompt, provider);
  if (bridgeCommand && (await runBridgeCommand(channel, task, repo, beforeGit, bridgeCommand))) {
    return;
  }
  // Materialize any phone-sent image attachments to disk and point the agent at
  // them. Done after the slash-command check so commands aren't affected.
  const attachments = materializeAttachments(task, cwd);
  let effectivePrompt = prompt;
  if (attachments.length) {
    const lines = attachments.map((a) => `- ${a.path}`).join("\n");
    effectivePrompt =
      `The user attached ${attachments.length} image file(s) to this message. ` +
      `Use your file Read tool to view ${attachments.length === 1 ? "it" : "them"}:\n${lines}\n\n${prompt}`;
  }
  const promptForCli = taskWantsBridgeInstructions(task, prompt)
    ? taskPromptWithBridgeInstructions(provider, effectivePrompt, repo)
    : effectivePrompt;
  const built = buildCommand(provider, promptForCli, chatId, task);
  if (!built) {
    channel.push("error", { provider, chatId, message: `Unknown provider: ${provider}` });
    return;
  }

  let child;
  try {
    child = spawn(built.cmd, built.args, { cwd, stdio: ["ignore", "pipe", "pipe"] });
  } catch (err) {
    channel.push("error", { provider, chatId, message: `Could not start ${built.cmd}: ${err.message}`, replyToId });
    return;
  }
  const spawnAt = Date.now();
  console.log(
    `[vibe-bridge] latency recv→spawn=${spawnAt - recvAt}ms ` +
      `chat=${chatId} task=${taskId} cmd=${built.cmd}`
  );

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
    intelligence: intelligenceFor(task),
    speed: speedFor(task),
    reasoningEffort: reasoningEffortFor(provider, task),
    command: compactCommand(built.cmd, built.args),
    teamMode: task.teamMode || task.team_mode || null,
    teamRunId: task.teamRunId || task.team_run_id || null,
    teamWorker: task.teamWorker || task.team_worker || null,
    teamWorkers: Array.isArray(task.teamWorkers)
      ? task.teamWorkers
      : Array.isArray(task.team_workers)
        ? task.team_workers
        : [],
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
    model: modelFor(provider, chatId, task) || null,
    intelligence: intelligenceFor(task),
    speed: speedFor(task),
    reasoningEffort: reasoningEffortFor(provider, task),
    teamMode: task.teamMode || task.team_mode || null,
    teamRunId: task.teamRunId || task.team_run_id || null,
    teamWorker: task.teamWorker || task.team_worker || null,
    teamWorkers: Array.isArray(task.teamWorkers)
      ? task.teamWorkers
      : Array.isArray(task.team_workers)
        ? task.team_workers
        : [],
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
      intelligence: intelligenceFor(task),
      speed: speedFor(task),
      reasoningEffort: reasoningEffortFor(provider, task),
      command: compactCommand(built.cmd, built.args),
    }),
  });
  let output = "";
  let lineBuf = "";
  let progressCount = 1;
  let canceled = false;
  let firstOutputLogged = false;
  let lastProgressLogAt = 0;

  const onChunk = (buf) => {
    const text = buf.toString();
    if (!firstOutputLogged) {
      firstOutputLogged = true;
      const now = Date.now();
      console.log(
        `[vibe-bridge] latency first-output spawn→first=${now - spawnAt}ms ` +
          `recv→first=${now - recvAt}ms chat=${chatId} task=${taskId}`
      );
    }
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
        const now = Date.now();
        if (progressCount <= 4 || progressCount % 10 === 0 || now - lastProgressLogAt > 5000) {
          lastProgressLogAt = now;
          console.log(
            `[vibe-bridge] latency progress#${progressCount} recv→push=${now - recvAt}ms ` +
              `spawn→push=${now - spawnAt}ms bytes=${output.length} chat=${chatId} task=${taskId}`
          );
        }
        channel.push("progress", {
          provider,
          chatId,
          taskId,
          sequence: progressCount,
          sentAtMs: now,
          replyToId,
          repoId: repo.id,
          repoName: repo.name,
          cwd,
          workMode: workModeFor(task),
          model: modelFor(provider, chatId, task) || null,
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
    // The run is done — re-push this chat's transcript so the live "running" flag on
    // the last turn clears and the phone collapses it into the "Worked" card.
    refireHistoryWatch(chatId);
    // The agent has finished reading them — don't leave image attachments in the repo.
    for (const attachment of attachments) {
      try {
        fs.unlinkSync(attachment.path);
      } catch (_) {}
    }
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
    const resultPayload = {
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
      ...teamFieldsForTask(task),
      ...runtimeResultField(agentRuntime),
      ...liveAgentActionsField(provider, output),
    };
    rememberFinishedTask(key, {
      provider,
      chatId,
      taskId,
      repo,
      runtime: agentRuntime,
      finishedAt: Date.now(),
      // Kept so a result that lands while the socket is down can be re-pushed on
      // reconnect (see the rejoin recovery in connect()).
      resultPayload,
    });
    rememberRuntime(provider, chatId, agentRuntime);
    channel.push("result", resultPayload);
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
const HISTORY_MSG_LIMIT = 600;

function clip(value, n) {
  if (typeof value !== "string") return "";
  const s = value.replace(/\s+/g, " ").trim();
  return s.length > n ? s.slice(0, n - 1) + "…" : s;
}

// Length-cap a string WITHOUT destroying its line structure. clip() collapses
// every whitespace run (incl. "\n") to a single space — correct for one-line
// labels (bash command, topic title) but it flattens markdown answers, narration
// prose, and terminal output into a single paragraph. clipText preserves newlines
// and intra-line indentation (diffs, code, JSON), only trimming trailing spaces
// per line and capping runaway blank-line runs, then applies the length cap.
function clipText(value, n) {
  if (typeof value !== "string") return "";
  const s = value
    .replace(/\r\n?/g, "\n")
    .replace(/[ \t]+\n/g, "\n")
    .replace(/\n{4,}/g, "\n\n\n")
    .trim();
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

// ── History runtime reconstruction ──────────────────────────────────
// Browsing a past session must show the same "N files changed +X −Y" card the
// live run produces — including sessions you ran directly on your computer
// (not from the phone). The live path diffs the working tree; history can't
// (the tree has moved on, or the run happened elsewhere), so we rebuild the
// card from the transcript's own edit operations: Claude `tool_use`
// (Edit/MultiEdit/Write/NotebookEdit) and Codex `apply_patch` envelopes. The
// output is the exact `diff` shape runtimePayload() emits, so the iOS card
// renders unchanged, and it is sealed via runtimeResultField() → the server
// only ever sees ciphertext.
const MAX_RUNTIME_FILES = 80;

function countTextLines(value) {
  const s = value == null ? "" : String(value);
  if (s === "") return 0;
  const trimmed = s.replace(/\n+$/, "");
  return trimmed === "" ? 1 : trimmed.split("\n").length;
}

function newRuntimeAccumulator() {
  return { byPath: new Map(), order: [], additions: 0, deletions: 0, patch: "", patchTruncated: false };
}

function accumulateRuntimeFile(acc, filePath, status, additions, deletions, patchBlock) {
  const clean = diffFilePath(filePath);
  if (!clean) return;
  let entry = acc.byPath.get(clean);
  if (!entry) {
    entry = { path: clean, name: path.basename(clean), status, additions: 0, deletions: 0 };
    acc.byPath.set(clean, entry);
    acc.order.push(clean);
  } else if (entry.status !== status && entry.status !== "A" && entry.status !== "A?") {
    entry.status = status === "D" ? "D" : "M";
  }
  entry.additions += additions;
  entry.deletions += deletions;
  acc.additions += additions;
  acc.deletions += deletions;
  if (patchBlock && !acc.patchTruncated) {
    if (acc.patch.length + patchBlock.length > MAX_DIFF_BYTES) acc.patchTruncated = true;
    else acc.patch += patchBlock;
  }
}

// Build a git-style unified block from a before/after string pair.
function unifiedDiffBlock(filePath, oldStr, newStr, status) {
  const rel = diffFilePath(filePath);
  if (!rel) return "";
  const oldLines = oldStr == null || oldStr === "" ? [] : String(oldStr).replace(/\n$/, "").split("\n");
  const newLines = newStr == null || newStr === "" ? [] : String(newStr).replace(/\n$/, "").split("\n");
  const header =
    `diff --git a/${rel} b/${rel}\n` +
    (status === "A"
      ? `new file mode 100644\n--- /dev/null\n+++ b/${rel}\n`
      : `--- a/${rel}\n+++ b/${rel}\n`) +
    `@@ -${oldLines.length ? "1," + oldLines.length : "0,0"} +${newLines.length ? "1," + newLines.length : "0,0"} @@\n`;
  const body =
    (oldLines.length ? oldLines.map((l) => "-" + l).join("\n") + "\n" : "") +
    (newLines.length ? newLines.map((l) => "+" + l).join("\n") + "\n" : "");
  return header + body;
}

// Claude assistant content blocks → accumulate file edits.
function collectClaudeEdits(acc, content) {
  if (!Array.isArray(content)) return;
  for (const b of content) {
    if (!b || b.type !== "tool_use") continue;
    const inp = b.input || {};
    if (b.name === "Edit") {
      const oldS = inp.old_string || "";
      const newS = inp.new_string || "";
      accumulateRuntimeFile(acc, inp.file_path, "M", countTextLines(newS), countTextLines(oldS), unifiedDiffBlock(inp.file_path, oldS, newS, "M"));
    } else if (b.name === "MultiEdit" && Array.isArray(inp.edits)) {
      for (const e of inp.edits) {
        const oldS = (e && e.old_string) || "";
        const newS = (e && e.new_string) || "";
        accumulateRuntimeFile(acc, inp.file_path, "M", countTextLines(newS), countTextLines(oldS), unifiedDiffBlock(inp.file_path, oldS, newS, "M"));
      }
    } else if (b.name === "Write") {
      const body = inp.content || "";
      accumulateRuntimeFile(acc, inp.file_path, "A", countTextLines(body), 0, unifiedDiffBlock(inp.file_path, "", body, "A"));
    } else if (b.name === "NotebookEdit") {
      const target = inp.notebook_path || inp.file_path;
      const oldS = inp.old_source || "";
      const newS = inp.new_source || "";
      accumulateRuntimeFile(acc, target, "M", countTextLines(newS), countTextLines(oldS), unifiedDiffBlock(target, oldS, newS, "M"));
    }
  }
}

// Codex `apply_patch` envelope → accumulate file edits. Codex emits these as a
// `custom_tool_call` (sometimes `function_call`) whose `input` is the classic
// `*** Begin Patch / *** Add|Update|Delete File:` text.
function collectCodexEdits(acc, payload) {
  const p = payload;
  if (!p) return;
  const isPatch =
    (p.type === "custom_tool_call" || p.type === "function_call") && /apply_patch/i.test(p.name || "");
  if (!isPatch) return;
  const input = typeof p.input === "string" ? p.input : typeof p.arguments === "string" ? p.arguments : "";
  if (!input) return;
  for (const f of parseApplyPatchEnvelope(input)) {
    accumulateRuntimeFile(acc, f.path, f.status, f.additions, f.deletions, f.patchBlock);
  }
}

function parseApplyPatchEnvelope(input) {
  const lines = String(input).split("\n");
  const files = [];
  let cur = null;
  const flush = () => {
    if (cur) files.push(cur);
    cur = null;
  };
  for (const line of lines) {
    const mAdd = line.match(/^\*\*\* Add File: (.+)$/);
    const mUpd = line.match(/^\*\*\* Update File: (.+)$/);
    const mDel = line.match(/^\*\*\* Delete File: (.+)$/);
    if (mAdd || mUpd || mDel) {
      flush();
      cur = { path: (mAdd || mUpd || mDel)[1].trim(), status: mAdd ? "A" : mDel ? "D" : "M", additions: 0, deletions: 0, body: [] };
      continue;
    }
    if (/^\*\*\* /.test(line)) continue; // Begin Patch / End Patch / Move to: …
    if (!cur) continue;
    cur.body.push(line);
    if (line.startsWith("+") && !line.startsWith("+++")) cur.additions++;
    else if (line.startsWith("-") && !line.startsWith("---")) cur.deletions++;
  }
  flush();
  return files.map((f) => {
    const rel = diffFilePath(f.path);
    const head =
      `diff --git a/${rel} b/${rel}\n` +
      (f.status === "A"
        ? `new file mode 100644\n--- /dev/null\n+++ b/${rel}\n`
        : f.status === "D"
          ? `deleted file mode 100644\n--- a/${rel}\n+++ /dev/null\n`
          : `--- a/${rel}\n+++ b/${rel}\n`);
    const body = f.body.join("\n");
    return {
      path: rel,
      status: f.status,
      additions: f.additions,
      deletions: f.deletions,
      patchBlock: head + (body ? body + (body.endsWith("\n") ? "" : "\n") : ""),
    };
  });
}

// Elapsed time of a turn from its first (user prompt) to last (assistant) event
// timestamp. Returns undefined when either timestamp is missing/unparseable.
function turnDurationMs(startTs, endTs) {
  if (!startTs || !endTs) return undefined;
  const a = Date.parse(startTs);
  const b = Date.parse(endTs);
  if (Number.isNaN(a) || Number.isNaN(b) || b < a) return undefined;
  return b - a;
}

function buildHistoryRuntime(provider, acc, durationMs) {
  if (!acc.order.length) return null;
  const files = acc.order.map((p) => acc.byPath.get(p));
  return {
    provider,
    status: "done",
    workMode: "history",
    // Per-turn elapsed time reconstructed from the transcript timestamps so the
    // phone's "Worked for Xs · N steps" line reads the same on history as live.
    ...(typeof durationMs === "number" && durationMs > 0 ? { durationMs } : {}),
    diff: {
      git: false,
      filesChanged: files.length,
      additions: acc.additions,
      deletions: acc.deletions,
      files,
      patch: acc.patch,
      patchTruncated: acc.patchTruncated,
    },
    controls: { canCancel: false, canRevert: false },
  };
}

// Seal ONE turn's reconstructed runtime onto a specific message, so each turn
// shows the patch IT applied — inline, where it happened (matching the Codex
// app) — instead of one consolidated card dumped at the end of the session.
function sealHistoryRuntime(provider, message, acc, durationMs) {
  const runtime = buildHistoryRuntime(provider, acc, durationMs);
  if (!runtime) return false;
  const field = runtimeResultField(runtime);
  if (!field || !field.agentRuntimeEnc) return false; // no key → never send plaintext
  Object.assign(message, field);
  return true;
}

// A real user prompt (not a tool_result/tool-output envelope) opens a new turn.
function messageHasUserText(m) {
  if (!m) return false;
  if (typeof m.content === "string") return m.content.trim().length > 0;
  if (Array.isArray(m.content)) {
    return m.content.some((b) => b && b.type === "text" && String(b.text || "").trim().length > 0);
  }
  return false;
}

// A session is "live" when its transcript file is actively being appended to (a
// turn is in flight) — detected by a recent mtime — OR when it matches a task the
// bridge itself spawned and is still running. This lets the phone show a live badge
// in history (and open it as a live stream) for sessions started EITHER by the
// bridge OR directly in the user's own desktop terminal (which never enter the
// `runningTasks` Map, so mtime-freshness is the only signal we have for those).
const LIVE_SESSION_WINDOW_MS = 75_000;

function runningSessionIdSet(provider) {
  const set = new Set();
  const want = String(provider || "").trim().toLowerCase();
  for (const entry of runningTasks.values()) {
    if (want && entry.provider && String(entry.provider).toLowerCase() !== want) continue;
    if (entry.sessionId) set.add(entry.sessionId);
  }
  return set;
}

function sessionIsLive(mtime, id, runningIds) {
  if (id && runningIds && runningIds.has(id)) return true;
  return mtime != null && Date.now() - mtime < LIVE_SESSION_WINDOW_MS;
}

async function listClaude(limit) {
  const files = claudeSessionFiles().sort((a, b) => b.mtime - a.mtime).slice(0, limit);
  const runningIds = runningSessionIdSet("claude");
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
      live: sessionIsLive(s.mtime, s.id, runningIds),
    });
  }
  return results;
}

// Human-readable one-liners for tool actions, so a session watched live shows
// what the agent is DOING (running a command, editing a file) in-line — not
// just its text and a summary card. Applied to the trailing in-progress turn.
function safeBase(x) {
  try { return path.basename(String(x || "")); } catch (_) { return String(x || ""); }
}
function claudeActionLine(b) {
  const inp = b.input || {};
  switch (b.name) {
    case "Bash": {
      const cmd = String(inp.command || "").replace(/\s+/g, " ").trim();
      return cmd ? "⚡ $ " + clip(cmd, 160) : "⚡ Bash";
    }
    case "Edit":
    case "MultiEdit": return "✏️ Edit " + safeBase(inp.file_path);
    case "Write": return "📝 Write " + safeBase(inp.file_path);
    case "NotebookEdit": return "✏️ Edit " + safeBase(inp.notebook_path || inp.file_path);
    case "Read": return "📖 Read " + safeBase(inp.file_path);
    case "Grep": return "🔎 Grep " + clip(String(inp.pattern || ""), 80);
    case "Glob": return "🔎 Glob " + clip(String(inp.pattern || ""), 80);
    case "TodoWrite": return "✅ Updated todos";
    case "Task": return "🤖 " + clip(String(inp.description || "subagent"), 80);
    case "WebFetch": return "🌐 " + clip(String(inp.url || ""), 80);
    case "WebSearch": return "🌐 Search " + clip(String(inp.query || ""), 80);
    default: return "🔧 " + (b.name || "tool");
  }
}
function codexActionLine(p) {
  const name = String(p.name || "");
  if (/apply_patch/i.test(name)) {
    const input = typeof p.input === "string" ? p.input : typeof p.arguments === "string" ? p.arguments : "";
    const files = parseApplyPatchEnvelope(input).map((f) => safeBase(f.path));
    return "✏️ Edit " + (files.length ? clip(files.join(", "), 120) : "files");
  }
  if (isCodexShellToolName(name)) {
    const cmd = codexCommandFromPayload(p);
    return cmd ? "⚡ $ " + clip(cmd, 160) : "⚡ shell";
  }
  return "🔧 " + (name || "tool");
}

// ── Structured tool detail (E2E-encrypted) ──────────────────────────
// The one-line action label above stays plaintext (it is already in the known
// Tier-2 gap: command strings + prose reach the server). The SENSITIVE detail —
// command OUTPUT, todo contents, diff counts, search hits — rides a per-message
// `agentActionEnc` blob encrypted with the SAME arte1 key as the diff card, so
// the server stays zero-knowledge. The phone joins detail→entry by `uid` and
// renders a rich inline card (collapsible command+output, todo list, …).
// `read` is included so the file slice Claude read rides the encrypted blob and
// powers the read row's "expand to full file" layer (line range still shows in the
// plaintext preview via the node's start/end).
const OUTPUT_KINDS = new Set(["bash", "search", "task", "web", "tool", "read"]);
const MAX_ACTION_OUTPUT = 4000;
// Per-edit unified-diff cap (rides the encrypted blob for the edit row's patch layer).
const MAX_NODE_PATCH = 6000;

function toolResultText(content) {
  if (content == null) return "";
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .map((b) => (typeof b === "string" ? b : b && typeof b.text === "string" ? b.text : ""))
      .filter(Boolean)
      .join("\n");
  }
  if (typeof content === "object" && typeof content.text === "string") return content.text;
  return "";
}

function claudeActionDetail(b) {
  const inp = b.input || {};
  switch (b.name) {
    case "Bash":
      return { kind: "bash", command: String(inp.command || ""), description: inp.description ? String(inp.description) : "" };
    case "Edit":
      return { kind: "edit", path: diffFilePath(inp.file_path), name: safeBase(inp.file_path), additions: countTextLines(inp.new_string), deletions: countTextLines(inp.old_string), patch: clipText(unifiedDiffBlock(inp.file_path, inp.old_string || "", inp.new_string || "", "M"), MAX_NODE_PATCH) };
    case "MultiEdit": {
      let add = 0, del = 0, patch = "";
      if (Array.isArray(inp.edits)) for (const e of inp.edits) {
        const oldS = (e && e.old_string) || "", newS = (e && e.new_string) || "";
        add += countTextLines(newS); del += countTextLines(oldS);
        patch += unifiedDiffBlock(inp.file_path, oldS, newS, "M");
      }
      return { kind: "edit", path: diffFilePath(inp.file_path), name: safeBase(inp.file_path), additions: add, deletions: del, patch: clipText(patch, MAX_NODE_PATCH) };
    }
    case "Write":
      return { kind: "write", path: diffFilePath(inp.file_path), name: safeBase(inp.file_path), additions: countTextLines(inp.content), patch: clipText(unifiedDiffBlock(inp.file_path, "", inp.content || "", "A"), MAX_NODE_PATCH) };
    case "NotebookEdit":
      return { kind: "edit", path: diffFilePath(inp.notebook_path || inp.file_path), name: safeBase(inp.notebook_path || inp.file_path), additions: countTextLines(inp.new_source), deletions: countTextLines(inp.old_source), patch: clipText(unifiedDiffBlock(inp.notebook_path || inp.file_path, inp.old_source || "", inp.new_source || "", "M"), MAX_NODE_PATCH) };
    case "Read": {
      // Carry the line range Claude requested so the row preview reads "Read foo.swift (12–48)";
      // the file slice itself rides the encrypted blob (read ∈ OUTPUT_KINDS) for the expand layer.
      const d = { kind: "read", path: diffFilePath(inp.file_path), name: safeBase(inp.file_path) };
      const offset = Number(inp.offset), limit = Number(inp.limit);
      if (Number.isFinite(offset) && offset > 0) {
        d.start = offset;
        if (Number.isFinite(limit) && limit > 0) d.end = offset + limit - 1;
      } else if (Number.isFinite(limit) && limit > 0) {
        d.start = 1; d.end = limit;
      }
      return d;
    }
    case "Grep":
      return { kind: "search", tool: "grep", pattern: String(inp.pattern || ""), path: inp.path ? String(inp.path) : "", glob: inp.glob ? String(inp.glob) : "" };
    case "Glob":
      return { kind: "search", tool: "glob", pattern: String(inp.pattern || ""), path: inp.path ? String(inp.path) : "" };
    case "TodoWrite":
      return { kind: "todo", todos: Array.isArray(inp.todos) ? inp.todos.map((t) => ({ content: String((t && t.content) || ""), status: String((t && t.status) || ""), activeForm: String((t && t.activeForm) || "") })) : [] };
    case "Task":
      return { kind: "task", description: String(inp.description || ""), subagent: String(inp.subagent_type || "") };
    case "WebFetch":
      return { kind: "web", url: String(inp.url || ""), prompt: clip(String(inp.prompt || ""), 200) };
    case "WebSearch":
      return { kind: "web", query: String(inp.query || "") };
    default:
      return { kind: "tool", name: String(b.name || "tool") };
  }
}

function codexActionDetail(p) {
  const name = String(p.name || "");
  if (/apply_patch/i.test(name)) {
    const input = typeof p.input === "string" ? p.input : typeof p.arguments === "string" ? p.arguments : "";
    const files = parseApplyPatchEnvelope(input);
    return {
      kind: "edit",
      name: files.map((f) => safeBase(f.path)).join(", "),
      path: files[0] ? files[0].path : "",
      additions: files.reduce((s, f) => s + (f.additions || 0), 0),
      deletions: files.reduce((s, f) => s + (f.deletions || 0), 0),
      files: files.length,
    };
  }
  if (isCodexShellToolName(name)) {
    const cmd = codexCommandFromPayload(p);
    return { kind: "bash", command: String(cmd || ""), description: "" };
  }
  return { kind: "tool", name: name || "tool" };
}

function isCodexShellToolName(name) {
  return ["shell", "local_shell", "container.exec", "exec_command"].includes(String(name || ""));
}

function codexCommandFromPayload(p) {
  let args = {};
  try {
    if (typeof p.arguments === "string") args = JSON.parse(p.arguments) || {};
    else if (typeof p.input === "string") args = JSON.parse(p.input) || {};
    else if (p.arguments && typeof p.arguments === "object") args = p.arguments;
    else if (p.input && typeof p.input === "object") args = p.input;
  } catch (_) {}
  let cmd = args.command || args.cmd;
  if (Array.isArray(cmd)) cmd = cmd.join(" ");
  return String(cmd || "").replace(/\s+/g, " ").trim();
}

// Codex emits the command result as a separate `function_call_output` whose
// `output` is sometimes a JSON-wrapped string. Pull out the readable text.
function codexOutputText(output) {
  if (output == null) return "";
  if (typeof output === "string") {
    try {
      const o = JSON.parse(output);
      if (o && typeof o.output === "string") return o.output;
      if (o && typeof o.aggregated_output === "string") return o.aggregated_output;
      if (o && (typeof o.stdout === "string" || typeof o.stderr === "string")) {
        return [o.stdout, o.stderr].filter(Boolean).join("\n");
      }
      if (o && typeof o.content === "string") return o.content;
    } catch (_) {}
    return output;
  }
  if (typeof output === "object") {
    if (typeof output.output === "string") return output.output;
    if (typeof output.aggregated_output === "string") return output.aggregated_output;
    if (typeof output.stdout === "string" || typeof output.stderr === "string") {
      return [output.stdout, output.stderr].filter(Boolean).join("\n");
    }
    return toolResultText(output.content);
  }
  return "";
}

function parsedJsonlEvents(output) {
  return String(output || "")
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean)
    .flatMap((line) => {
      try {
        const parsed = JSON.parse(line);
        if (Array.isArray(parsed)) return parsed.filter((item) => item && typeof item === "object");
        if (parsed && typeof parsed === "object") return [parsed];
      } catch (_) {}
      return [];
    });
}

function eventContentBlocks(event) {
  const content =
    event && event.message && Array.isArray(event.message.content)
      ? event.message.content
      : event && Array.isArray(event.content)
        ? event.content
        : null;
  return Array.isArray(content) ? content.filter((block) => block && typeof block === "object") : [];
}

function actionListFromMaps(order, detailByUid, resultByUid) {
  const seen = new Set();
  const actions = [];
  for (const uid of order) {
    if (!uid || seen.has(uid)) continue;
    seen.add(uid);
    const detail = detailByUid.get(uid);
    if (!detail) continue;
    if (OUTPUT_KINDS.has(detail.kind)) {
      const result = resultByUid.get(uid);
      if (result && result.output) {
        detail.output = result.output;
        detail.isError = !!result.isError;
      }
    }
    actions.push(Object.assign({ id: String(uid) }, detail));
  }
  return actions.slice(-60);
}

function liveAgentActionsField(provider, output) {
  const actions = provider === "codex" ? liveCodexActions(output) : liveClaudeActions(output);
  if (!actions.length) return {};
  const enc = encryptRuntimeBlob({ actions });
  return enc ? { agentActionsEnc: enc } : {};
}

function liveClaudeActions(output) {
  const detailByUid = new Map();
  const resultByUid = new Map();
  const order = [];
  for (const event of parsedJsonlEvents(output)) {
    // Live stream-json tags every subagent event with the parent Task's tool_use id;
    // carry it onto the child detail so the node lands at depth 1 / parentId.
    const parentToolUseId =
      typeof event.parent_tool_use_id === "string" && event.parent_tool_use_id
        ? event.parent_tool_use_id
        : "";
    for (const block of eventContentBlocks(event)) {
      if (block.type === "tool_use") {
        const id = block.id || `claude-tool-${order.length}`;
        order.push(id);
        const det = claudeActionDetail(block);
        if (parentToolUseId) det.parentId = parentToolUseId;
        detailByUid.set(id, det);
      } else if (block.type === "tool_result") {
        const id = block.tool_use_id || block.id;
        if (id) {
          resultByUid.set(id, {
            output: clipText(toolResultText(block.content || block.text || block.result), MAX_ACTION_OUTPUT),
            isError: !!block.is_error,
          });
        }
      }
    }
  }
  return actionListFromMaps(order, detailByUid, resultByUid);
}

function codexLiveItem(event) {
  if (!event || typeof event !== "object") return null;
  if (event.item && typeof event.item === "object") return event.item;
  if (event.type === "response_item" && event.payload && typeof event.payload === "object") return event.payload;
  if (event.payload && typeof event.payload === "object" && (event.payload.type || event.payload.item_type)) return event.payload;
  return null;
}

function codexLiveItemType(item) {
  return item && String(item.item_type || item.type || "").trim();
}

function codexLiveNodeId(event, item, index) {
  return (
    (item && (item.call_id || item.id)) ||
    (event && event.id) ||
    `codex-tool-${index}`
  );
}

function codexCommandExecutionDetail(item) {
  let cmd = item.command || item.cmd;
  if (Array.isArray(cmd)) cmd = cmd.join(" ");
  if (!cmd && item.input && typeof item.input === "object") cmd = item.input.command || item.input.cmd;
  return { kind: "bash", command: String(cmd || "").replace(/\s+/g, " ").trim(), description: "" };
}

function liveCodexActions(output) {
  const detailByUid = new Map();
  const resultByUid = new Map();
  const callIdToUid = new Map();
  const order = [];
  parsedJsonlEvents(output).forEach((event, index) => {
    const item = codexLiveItem(event);
    if (!item) return;
    const type = codexLiveItemType(item);
    if (!type || ["agent_message", "reasoning", "message"].includes(type)) return;

    if (type === "function_call_output" || type === "custom_tool_call_output") {
      const uid = item.call_id ? callIdToUid.get(item.call_id) || item.call_id : codexLiveNodeId(event, item, index);
      if (uid) {
        resultByUid.set(uid, {
          output: clipText(codexOutputText(item.output || item.result || item.content), MAX_ACTION_OUTPUT),
          isError: !!item.is_error,
        });
      }
      return;
    }

    const uid = codexLiveNodeId(event, item, index);
    if (item.call_id) callIdToUid.set(item.call_id, uid);

    if (type === "command_execution") {
      detailByUid.set(uid, codexCommandExecutionDetail(item));
      order.push(uid);
      const outputText = codexOutputText(item.aggregated_output || item.stdout || item.stderr || item.output);
      if (outputText) {
        resultByUid.set(uid, {
          output: clipText(outputText, MAX_ACTION_OUTPUT),
          isError: typeof item.exit_code === "number" && item.exit_code !== 0,
        });
      }
      return;
    }

    if (type === "function_call" || type === "custom_tool_call") {
      detailByUid.set(uid, codexActionDetail(item));
      order.push(uid);
      return;
    }

    if (type === "file_change") {
      const paths = Array.isArray(item.changes)
        ? item.changes.map((change) => change && (change.path || change.file_path)).filter(Boolean)
        : [item.path || item.file_path].filter(Boolean);
      detailByUid.set(uid, { kind: "edit", name: paths.map(safeBase).join(", "), path: paths[0] || "" });
      order.push(uid);
    }
  });
  return actionListFromMaps(order, detailByUid, resultByUid);
}

// Seal a structured tool detail onto its action message. Never sends plaintext:
// with no runtime key the rich card simply stays hidden (the label still shows).
function sealActionDetail(message, detail) {
  if (!detail) return false;
  const enc = encryptRuntimeBlob(detail);
  if (!enc) return false;
  message.agentActionEnc = enc;
  return true;
}

// ── Tool actions → native progress nodes (no emoji) ─────────────────
// The phone renders an assistant turn natively: a compact shimmer line that
// expands to a tool sheet (Read/Edit/Run …), then the prose, then the diff card.
// To feed that path we attach each turn's tool actions to its assistant message
// as `progressNodes` (plaintext labels — already in the Tier-2 gap) plus an
// E2E-encrypted `agentActionsEnc` carrying the SENSITIVE detail (command OUTPUT,
// todo contents, search hits). The node label is recomputed app-side from
// kind/target/added/removed; we still ship a clean (emoji-free) fallback label.
function actionNodeTarget(kind, d) {
  switch (kind) {
    case "bash": return clip(String(d.command || "").replace(/\s+/g, " ").trim(), 72);
    case "edit":
    case "write":
    case "read": return d.name || "";
    case "search": return clip(String(d.pattern || ""), 72);
    case "web": return d.url || d.query || "";
    case "task": return clip(String(d.description || ""), 72);
    default: return "";
  }
}
function cleanNodeLabel(kind, target, d) {
  switch (kind) {
    case "bash": return target ? "Run " + target : "Run command";
    case "edit": return "Edit " + (target || "file");
    case "write": return "Create " + (target || "file");
    case "read": return "Read " + (target || "file");
    case "search": return (d.tool ? d.tool : "Search") + (target ? " " + target : "");
    case "web": return "Fetch" + (target ? " " + target : "");
    case "task": return "Task" + (target ? " " + target : "");
    case "todo": return "Planning";
    case "thinking": return "Thinking";
    default: return d.name || "Tool";
  }
}
function actionNode(detail, uid, status) {
  const d = detail || {};
  const kind = d.kind || "tool";
  const target = actionNodeTarget(kind, d);
  // A subagent (Task tool) child carries the parent Task's tool_use id → depth 1
  // so the phone groups it under the Task instead of flattening it into the feed.
  const parentId = d.parentId ? String(d.parentId) : "";
  const node = {
    id: String(uid || ""),
    label: cleanNodeLabel(kind, target, d),
    kind,
    status: status || "done",
    depth: parentId ? 1 : 0,
  };
  if (parentId) node.parentId = parentId;
  // The parent Task node advertises the subagent flavor (e.g. "explore") so the
  // phone can render "🤖 Subagent · explore" and open its read-only view.
  if (kind === "task" && d.subagent) node.subagentType = String(d.subagent);
  if (target) node.target = target;
  if (typeof d.additions === "number" && d.additions > 0) node.added = d.additions;
  if (typeof d.deletions === "number" && d.deletions > 0) node.removed = d.deletions;
  // Read line range — plaintext (line numbers aren't sensitive) so the row preview can
  // show "Read foo.swift (12–48)" without needing the decrypted blob.
  if (typeof d.start === "number" && d.start > 0) node.start = d.start;
  if (typeof d.end === "number" && d.end > 0) node.end = d.end;
  return node;
}
// Build a turn's progress nodes + sealed detail array and attach them to the
// turn's host message (its final assistant text, or a synthetic empty assistant
// message when the turn produced only tool calls). Output/contents are joined
// from `resultByUid` and ride ONLY the encrypted blob.
function attachTurnActions(messages, host, uids, detailByUid, resultByUid) {
  const nodes = [];
  const actions = [];
  for (const uid of uids) {
    const det = detailByUid.get(uid);
    if (!det) continue;
    if (OUTPUT_KINDS.has(det.kind)) {
      const r = resultByUid.get(uid);
      if (r) { det.output = r.output; det.isError = r.isError; }
    }
    nodes.push(actionNode(det, uid, det.isError ? "error" : "done"));
    actions.push(Object.assign({ id: String(uid) }, det));
  }
  if (!nodes.length) return;
  let target = host;
  if (!target) {
    target = { role: "assistant", text: "", uid: "actions-" + String(uids[0] || nodes.length) };
    messages.push(target);
  }
  // Cap to keep a single turn's feed bounded on pathological sessions.
  target.progressNodes = nodes.slice(-60);
  const enc = encryptRuntimeBlob({ actions: actions.slice(-60) });
  if (enc) target.agentActionsEnc = enc;
}

// Fold ONE user-turn into a SINGLE assistant "host" message. The turn's LAST
// assistant text becomes the host's visible summary (rendered OUTSIDE the card);
// every earlier assistant text plus all tool actions become interleaved progress
// nodes (rendered INSIDE the "Worked for Xs" card) in chronological order — so a
// turn reads as one collapsed card + one summary, never a pile of separate text
// bubbles with a stray "Worked" card wedged between them (the bug this fixes).
// `turnItems` is the ordered list captured during the turn:
//   { type:"text", text, uid, ts }  |  { type:"tool", uid, ts }
// Returns the host (already pushed onto `messages`) or null if the turn was empty.
function foldTurnIntoHost(messages, turnItems, detailByUid, resultByUid, turnReasoning, hostFallbackUid) {
  // The LAST non-empty text is the answer; it rides OUTSIDE the card.
  let lastTextIndex = -1;
  for (let i = 0; i < turnItems.length; i++) {
    if (turnItems[i].type === "text" && String(turnItems[i].text || "").trim()) lastTextIndex = i;
  }
  const summary = lastTextIndex >= 0 ? turnItems[lastTextIndex] : null;

  const nodes = [];
  const actions = [];
  // ONE "Thinking" node leads the turn's feed (reasoning rides the encrypted blob;
  // the label stays the generic, leak-free "Thinking").
  const reasoning = String(turnReasoning || "").trim();
  if (reasoning) {
    const tid = "think-host";
    const det = { kind: "thinking", output: clipText(reasoning, MAX_ACTION_OUTPUT) };
    nodes.push(actionNode(det, tid, "done"));
    actions.push(Object.assign({ id: tid }, det));
  }
  let textSeq = 0;
  for (let i = 0; i < turnItems.length; i++) {
    if (i === lastTextIndex) continue;   // the answer rides OUTSIDE the card
    const it = turnItems[i];
    if (it.type === "text") {
      // Interior narration → an in-card text node (phone renders it as prose,
      // interleaved with the tool rows, via VibeAgentKitMessageCell).
      const t = String(it.text || "").trim();
      if (!t) continue;
      nodes.push({
        id: it.uid ? "txt-" + String(it.uid) : "txt-" + textSeq++,
        label: clipText(t, 4000),
        kind: "text",
        status: "done",
        depth: 0,
      });
      continue;
    }
    const det = detailByUid.get(it.uid);
    if (!det) continue;
    if (OUTPUT_KINDS.has(det.kind)) {
      const r = resultByUid.get(it.uid);
      if (r) { det.output = r.output; det.isError = r.isError; }
    }
    nodes.push(actionNode(det, it.uid, det.isError ? "error" : "done"));
    actions.push(Object.assign({ id: String(it.uid) }, det));
  }

  if (!summary && !nodes.length) return null;

  // Key the host by the turn's FIRST event uid — stable across live-tail re-pushes.
  // (The "last text" changes as a turn streams, so keying by the summary would make
  // the row id jump mid-run and leave a stale bubble; the first event is fixed once
  // the turn opens, so the phone upserts the same row cleanly as the turn grows.)
  const hostUid =
    (turnItems[0] && turnItems[0].uid) ||
    (summary && summary.uid) ||
    hostFallbackUid ||
    ("turn-" + messages.length);
  const host = {
    role: "assistant",
    text: summary ? clipText(String(summary.text || "").trim(), 4000) : "",
    ts: (summary && summary.ts) || (turnItems.length && turnItems[turnItems.length - 1].ts) || null,
    uid: hostUid,
  };
  if (nodes.length) {
    host.progressNodes = nodes.slice(-60);
    const enc = encryptRuntimeBlob({ actions: actions.slice(-60) });
    if (enc) host.agentActionsEnc = enc;
  }
  messages.push(host);
  return host;
}

async function claudeDetail(id, limit) {
  const match = claudeSessionFiles().find((s) => s.id === id);
  if (!match) return null;
  const messages = [];
  let pending = newRuntimeAccumulator();
  let topic = null;
  // Claude Code re-appends prior messages (same `uuid`) into the JSONL every time a
  // session is resumed/compacted, so a long session contains the SAME message many
  // times over. Replaying those duplicates produced garbled "corpse" history and
  // repeated diff cards — dedupe by uuid so each message (and its edits) counts once.
  const seen = new Set();
  // Turn tracking: each user-text message starts a new turn. The turn's assistant
  // prose AND tool actions are captured IN ORDER, then folded into ONE host
  // message at flush (foldTurnIntoHost): the last text = the summary (outside the
  // card), every earlier text + all tools = interleaved progress nodes (inside the
  // "Worked" card). One compact, expandable turn — never a pile of text bubbles.
  let turnItems = [];      // ordered [{type:"text",text,uid,ts}|{type:"tool",uid,ts}]
  let turnReasoning = "";  // accumulated thinking for the current turn → ONE node
  let thinkSeq = 0;
  // Turn timespan (user prompt → last assistant event) → "Worked for Xs".
  let turnStartTs = null;
  let turnEndTs = null;
  // Structured tool detail join: uid → {kind, command, …} and
  // tool_use_id → {output, isError}.
  const actionDetailByUid = new Map();
  const resultByUid = new Map();
  // One card per user-turn: fold the turn's prose + tool feed into ONE host
  // message, then seal the edits/diff card onto it.
  const flushTurn = () => {
    const host = foldTurnIntoHost(messages, turnItems, actionDetailByUid, resultByUid, turnReasoning, null);
    if (host && pending.order.length) {
      sealHistoryRuntime("claude", host, pending, turnDurationMs(turnStartTs, turnEndTs));
    }
    pending = newRuntimeAccumulator();
    turnItems = [];
    turnReasoning = "";
    turnStartTs = null;
    turnEndTs = null;
  };
  await readJsonl(match.file, (ev) => {
    if (ev.type === "ai-title" && ev.aiTitle) topic = ev.aiTitle;
    if (ev.type !== "user" && ev.type !== "assistant") return;
    if (ev.uuid) { if (seen.has(ev.uuid)) return; seen.add(ev.uuid); }
    const m = ev.message || {};
    // /compact summaries are injected as user messages — render them as a
    // mid-chat divider (kind:"summary"), never a user bubble or a turn boundary.
    if (ev.type === "user" && ev.isCompactSummary) {
      let st = "";
      if (typeof m.content === "string") st = m.content;
      else if (Array.isArray(m.content)) st = m.content.filter((b) => b && b.type === "text").map((b) => b.text).join("\n").trim();
      st = cleanMessageText(st);
      if (st) messages.push({ role: "system", kind: "summary", text: clipText(st, 4000), ts: ev.timestamp, uid: ev.uuid });
      return;
    }
    // Capture tool results (bash stdout, …) to join onto their action entry.
    // These are user-type events carrying a tool_result block and no user text.
    if (ev.type === "user" && Array.isArray(m.content)) {
      for (const b of m.content) {
        if (b && b.type === "tool_result" && b.tool_use_id) {
          resultByUid.set(b.tool_use_id, { output: clipText(toolResultText(b.content), MAX_ACTION_OUTPUT), isError: !!b.is_error });
        }
      }
    }
    // Skip Claude Code's own meta annotations (local-command output, IDE
    // open/selection, caveats) — not conversation; they render as junk bubbles.
    if (ev.type === "user" && ev.isMeta) return;
    let rawText = "";
    if (typeof m.content === "string") rawText = m.content;
    else if (Array.isArray(m.content)) {
      rawText = m.content.filter((b) => b && b.type === "text").map((b) => b.text).join("\n").trim();
    }
    // Claude Code records a local slash-command invocation (/compact, /clear, …) as a
    // user event wrapping <command-name>/<local-command-stdout> chrome. It's UI, not
    // conversation — drop it BEFORE the turn-boundary flush so it neither seals a turn
    // nor leaks a junk "Compacted" user bubble next to the real summary divider. The
    // compaction SUMMARY itself is handled above (isCompactSummary → kind:"summary").
    if (ev.type === "user" && /<command-name>|<command-message>|<local-command-stdout>/i.test(rawText)) {
      return;
    }
    if (ev.type === "user" && messageHasUserText(m)) {
      flushTurn();                  // seal prior turn's card + action feed
      turnStartTs = ev.timestamp || null;   // new turn opens at this prompt
    }
    if (ev.type === "assistant") {
      collectClaudeEdits(pending, m.content);
      if (ev.timestamp) turnEndTs = ev.timestamp;   // extend turn end to last assistant event
    }
    let text = cleanMessageText(rawText);
    if (ev.type === "user") {
      // User prompts stay their own right-side bubble (each one is a turn boundary).
      if (text) messages.push({ role: "user", text: clipText(text, 4000), ts: ev.timestamp, uid: ev.uuid });
    } else if (ev.type === "assistant") {
      // Fold this assistant event into the current turn IN ORDER: its prose first
      // (an interior text becomes an in-card narration node; the turn's LAST text
      // becomes the summary), then its tool calls — so the card reads chronologically.
      if (text) turnItems.push({ type: "text", text, uid: ev.uuid, ts: ev.timestamp });
      if (Array.isArray(m.content)) {
        // Coalesce this message's reasoning into the turn's single "Thinking" node.
        // (Claude Code usually persists thinking with EMPTY text — only the
        // signature — so this is typically a no-op; it lights up if a session ever
        // stores summarized reasoning.)
        const think = m.content
          .filter((b) => b && b.type === "thinking" && b.thinking)
          .map((b) => String(b.thinking))
          .join("\n\n")
          .trim();
        if (think) turnReasoning += (turnReasoning ? "\n\n" : "") + think;
        // Subagent (sidechain) events carry the parent Task's tool_use id; tag the
        // child detail so it groups under the Task (depth 1) like the live path.
        const parentToolUseId =
          (typeof ev.parent_tool_use_id === "string" && ev.parent_tool_use_id) ||
          (typeof m.parent_tool_use_id === "string" && m.parent_tool_use_id) ||
          "";
        for (const b of m.content) {
          if (b && b.type === "tool_use") {
            turnItems.push({ type: "tool", uid: b.id, ts: ev.timestamp });
            const det = claudeActionDetail(b);
            if (parentToolUseId) det.parentId = parentToolUseId;
            actionDetailByUid.set(b.id, det);
          }
        }
      }
    }
  });
  flushTurn();
  // Keep the most RECENT `limit` messages (the tail), not the oldest — a long
  // session must show what's happening NOW, not its opening turns (this was the
  // "messages are too old" bug: reading stopped at `limit` from the top). The
  // per-turn cards + action feeds were sealed onto the message objects above, so
  // they ride along with whatever survives the trim. Stable `uid`s (not array
  // position) key the app-side upsert, so a sliding window re-pushes cleanly.
  const topicText = topic || (messages[0] && clip(messages[0].text, 80)) || "Untitled";
  // Flag a windowed tail so the app only runs aggressive stale-row cleanup when it
  // received the WHOLE session — otherwise "absent" just means "older than the
  // window", and deleting those would erase valid scrollback.
  const truncated = messages.length > limit;
  if (truncated) messages.splice(0, messages.length - limit);
  return { provider: "claude", id, topic: topicText, project: match.project, projectName: path.basename(match.project), truncated, messages };
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
  const runningIds = runningSessionIdSet("codex");
  const results = [];
  for (const f of files) {
    const sum = await codexSummary(f.file);
    if (sum.messages === 0) continue;
    const project = (sum.meta && sum.meta.cwd) || "";
    if (isEphemeralProject(project)) continue;
    const id = (sum.meta && sum.meta.id) || f.name;
    results.push({
      provider: "codex",
      id,
      topic: sum.topic,
      project,
      projectName: project ? path.basename(project) : "",
      updatedAt: sum.lastTs || new Date(f.mtime).toISOString(),
      messageCount: sum.messages,
      live: sessionIsLive(f.mtime, id, runningIds),
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
  let pending = newRuntimeAccumulator();
  let project = "";
  // Same guard as Claude: skip any response_item we've already processed (by id) so a
  // resumed/re-emitted rollout never replays a message or its apply_patch twice.
  const seen = new Set();
  // Per-turn prose+action collection, folded into ONE host message (see claudeDetail).
  let turnItems = [];      // ordered [{type:"text",text,uid,ts}|{type:"tool",uid,ts}]
  let turnReasoning = "";  // accumulated reasoning for the current turn → ONE node
  let thinkSeq = 0;
  // Turn timespan (user prompt → last assistant message) → "Worked for Xs".
  let turnStartTs = null;
  let turnEndTs = null;
  // Structured tool detail join. Codex references a call by `call_id` in the
  // separate output item, while the action entry is keyed by the message uid —
  // so callIdToUid bridges output → entry.
  const actionDetailByUid = new Map();
  const resultByUid = new Map();
  const callIdToUid = new Map();
  const flushTurn = () => {
    const host = foldTurnIntoHost(messages, turnItems, actionDetailByUid, resultByUid, turnReasoning, null);
    if (host && pending.order.length) {
      sealHistoryRuntime("codex", host, pending, turnDurationMs(turnStartTs, turnEndTs));
    }
    pending = newRuntimeAccumulator();
    turnItems = [];
    turnReasoning = "";
    turnStartTs = null;
    turnEndTs = null;
  };
  await readJsonl(match.file, (ev) => {
    if (ev.type === "session_meta" && ev.payload) project = ev.payload.cwd || "";
    if (ev.type !== "response_item" || !ev.payload) return;
    const p = ev.payload;
    const dkey = p.id || ev.id;
    if (dkey) { if (seen.has(dkey)) return; seen.add(dkey); }
    collectCodexEdits(pending, p); // apply_patch items accumulate into the turn
    if (p.type === "message" && (p.role === "user" || p.role === "assistant")) {
      const raw = codexText(p.content);
      if (p.role === "user" && raw.trim()) {
        flushTurn();                // seal prior turn's card + action feed
        turnStartTs = ev.timestamp || null;   // new turn opens at this prompt
      } else if (p.role === "assistant" && ev.timestamp) {
        turnEndTs = ev.timestamp;             // extend turn end to last assistant message
      }
      const text = cleanMessageText(raw);
      if (text && !isContextMessage(raw)) {
        if (p.role === "user") {
          // User prompts stay their own right-side bubble (turn boundary).
          messages.push({ role: "user", text: clipText(text, 4000), ts: ev.timestamp, uid: dkey });
        } else {
          // Assistant prose folds into the current turn IN ORDER (last text = summary).
          turnItems.push({ type: "text", text, uid: dkey, ts: ev.timestamp });
        }
      }
    } else if (p.type === "reasoning") {
      // Codex emits a reasoning item before nearly every tool call; aggregate the
      // whole turn's reasoning into ONE "Thinking" node (at flushTurn) so the feed
      // isn't flooded. Reasoning rides the encrypted blob (codex's own
      // `encrypted_content` is opaque to us; `summary` text is the readable gist).
      const think = (Array.isArray(p.summary)
        ? p.summary.map((s) => (s && s.text ? String(s.text) : "")).filter(Boolean).join("\n")
        : "").trim();
      if (think) turnReasoning += (turnReasoning ? "\n\n" : "") + think;
    } else if (p.type === "function_call" || p.type === "custom_tool_call") {
      // Collect the tool call for the current turn IN ORDER (output joins via call_id).
      turnItems.push({ type: "tool", uid: dkey, ts: ev.timestamp });
      actionDetailByUid.set(dkey, codexActionDetail(p));
      if (p.call_id) callIdToUid.set(p.call_id, dkey);
    } else if (p.type === "function_call_output" || p.type === "custom_tool_call_output") {
      const uid = p.call_id ? callIdToUid.get(p.call_id) : null;
      if (uid) resultByUid.set(uid, { output: clipText(codexOutputText(p.output), MAX_ACTION_OUTPUT), isError: false });
    }
  });
  flushTurn();
  // Topic from the FULL set (the opening message), then keep the most recent
  // `limit` messages — see claudeDetail for rationale (tail, not head; stable uid).
  const topic =
    messages.map((m) => cleanTopicCandidate(m.text)).find(Boolean) ||
    "Untitled";
  const truncated = messages.length > limit;
  if (truncated) messages.splice(0, messages.length - limit);
  return { provider: "codex", id, topic, project, projectName: project ? path.basename(project) : "", truncated, messages };
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

// ── Live transcript tail (directly-run sessions) ─────────────────────
// A `claude`/`codex` session the user started in their OWN terminal is never
// spawned by us via run_task, so it has no live stream — we only read it on
// demand. While the phone is viewing such a session we WATCH its JSONL and
// re-push the transcript as it grows, so the app upserts new turns live.
// Keyed by chatId, capped, polled via watchFile (robust to appends), and torn
// down on disconnect. Re-pushes reuse the ORIGINAL requestId so the app's
// existing ingest upserts in place — no server change needed.
const MAX_HISTORY_WATCHERS = 8;
const HISTORY_WATCH_DEBOUNCE_MS = 200; // coalesce rapid appends, then re-read
const historyWatchers = new Map(); // chatId -> watcher record

function sessionFilePath(provider, sessionId) {
  if (!sessionId) return null;
  const p = String(provider || "").trim().toLowerCase();
  const files = p === "codex" ? codexSessionFiles() : claudeSessionFiles();
  const match = files.find((s) => s.id === sessionId);
  return match ? match.file : null;
}

// True while any run_task is in flight for this chat — used to flag the live turn.
function isChatTaskRunning(chatId) {
  for (const entry of runningTasks.values()) {
    if (entry && entry.chatId === chatId) return true;
  }
  return false;
}

function runningTaskForChat(chatId) {
  for (const entry of runningTasks.values()) {
    if (entry && entry.chatId === chatId) return entry;
  }
  return null;
}

// True when the session's transcript file was appended to within the live window —
// the signal that a turn is in flight for a session the bridge did NOT spawn (a
// run the user started directly in their own desktop terminal).
function sessionFileIsLive(provider, sessionId) {
  const file = sessionFilePath(provider, sessionId);
  if (!file) return false;
  try {
    return Date.now() - fs.statSync(file).mtimeMs < LIVE_SESSION_WINDOW_MS;
  } catch (_) {
    return false;
  }
}

// Flag the trailing turn of a live session's detail payload as "working" so the
// phone renders the live state (shimmer + action feed) instead of collapsing to a
// finalized "Worked · N steps" card. Live = a bridge task is running for this chat
// OR the transcript file is still growing (desktop-terminal run). Returns true if
// the turn was marked.
function markDetailLiveTurn(result, provider, sessionId, chatId) {
  if (!result || result.mode !== "detail") return false;
  const msgs = result.session && result.session.messages;
  if (!Array.isArray(msgs) || !msgs.length) return false;
  if (!runningTaskForChat(chatId) && !sessionFileIsLive(provider, sessionId)) return false;
  const last = msgs[msgs.length - 1];
  if (last && last.role === "assistant") {
    markMessageRunning(last);
    // NOTE: we deliberately do NOT fold the turn's narration "text" nodes out of
    // progressNodes into message.text here. The phone SUPPRESSES the message body
    // while a turn is live, so moving prose into the body made live turns render
    // "commands only" (no narration). Keeping the text nodes inside progressNodes
    // lets the live feed interleave them with the tool steps (Read → text → Edit),
    // matching the agent-stream live path and the finished "Worked" card.
    return true;
  }
  return false;
}

function markMessageRunning(message) {
  if (!message || typeof message !== "object") return message;
  message.running = true;
  const nodes = Array.isArray(message.progressNodes) ? message.progressNodes : [];
  for (let i = nodes.length - 1; i >= 0; i--) {
    const node = nodes[i];
    if (!node || typeof node !== "object") continue;
    if (String(node.kind || "").trim().toLowerCase() === "text") continue;
    const status = String(node.status || "").trim().toLowerCase();
    if (["failed", "error", "cancelled", "canceled", "stopped"].includes(status)) continue;
    node.status = "running";
    break;
  }
  return message;
}

function runningPlaceholderMessage(entry) {
  if (!entry || !entry.taskId) return null;
  const providerTitle = entry.provider === "claude" ? "Claude" : entry.provider === "codex" ? "Codex" : "Agent";
  const target = entry.repo && entry.repo.name ? entry.repo.name : "";
  return {
    role: "assistant",
    text: "",
    uid: `running-${entry.taskId}`,
    ts: new Date(entry.startedAt || Date.now()).toISOString(),
    running: true,
    progressNodes: [
      {
        id: `running-${entry.taskId}`,
        label: `${providerTitle} is working`,
        kind: "task",
        status: "running",
        depth: 0,
        ...(target ? { target } : {}),
      },
    ],
  };
}

// Force the chat's history watcher to re-read + re-push even if the transcript text
// is unchanged (used when a run finishes so the live "running" flag flips to done).
function refireHistoryWatch(chatId) {
  const rec = historyWatchers.get(chatId);
  if (!rec) return;
  rec.lastSig = "";
  if (rec.schedule) rec.schedule();
}

function stopHistoryWatch(chatId) {
  const rec = historyWatchers.get(chatId);
  if (!rec) return;
  try { if (rec.watcher) rec.watcher.close(); } catch (_) {}
  try { if (rec.listener) fs.unwatchFile(rec.file, rec.listener); } catch (_) {}
  try { if (rec.debounce) clearTimeout(rec.debounce); } catch (_) {}
  try { if (rec.settle) clearTimeout(rec.settle); } catch (_) {}
  historyWatchers.delete(chatId);
}

function stopAllHistoryWatches() {
  for (const chatId of Array.from(historyWatchers.keys())) stopHistoryWatch(chatId);
}

function startHistoryWatch(channel, { chatId, provider, sessionId, echo }) {
  const file = sessionFilePath(provider, sessionId);
  if (!chatId || !sessionId || !file) return;
  // Remember the spec so the watch can be re-armed after a reconnect (the socket drop
  // calls stopAllHistoryWatches, which would otherwise leave the phone stuck on a stale
  // transcript until a full app restart).
  historyWatchSpecs.set(chatId, { provider, sessionId, echo });
  while (historyWatchSpecs.size > MAX_HISTORY_WATCHERS) {
    const oldest = historyWatchSpecs.keys().next().value;
    if (oldest === chatId || !oldest) break;
    historyWatchSpecs.delete(oldest);
  }
  stopHistoryWatch(chatId); // replace any prior watch for this chat
  if (historyWatchers.size >= MAX_HISTORY_WATCHERS) {
    const oldest = historyWatchers.keys().next().value;
    if (oldest) stopHistoryWatch(oldest);
  }
  const rec = { file, watcher: null, listener: null, debounce: null, lastSig: "", busy: false, again: false, schedule: null };
  const fire = () => {
    if (channel.state !== "joined") return;
    if (rec.busy) { rec.again = true; return; } // re-read once the in-flight read finishes
    rec.busy = true;
    readHistory({ provider, mode: "detail", sessionId })
      .then((result) => {
        const msgs = (result && result.session && result.session.messages) || [];
        const runningEntry = runningTaskForChat(chatId);
        // Live = a bridge task is running for this chat OR the transcript file is
        // still being appended to (a run the user started in their OWN terminal,
        // which never enters runningTasks). Either way the LAST turn is in flight —
        // flag it so the phone renders the live "working" state (shimmer + feed)
        // instead of collapsing to a "Worked · N steps" card. For bridge tasks the
        // flag clears on close (refireHistoryWatch); for desktop runs a settle timer
        // below re-fires once the file goes quiet so the final card seals.
        const liveByFile = sessionFileIsLive(provider, sessionId);
        const running = !!runningEntry || liveByFile;
        let last = msgs.length ? msgs[msgs.length - 1] : null;
        if (running && last && last.role === "assistant") {
          markMessageRunning(last);
          // Keep narration "text" nodes inside progressNodes (see markDetailLiveTurn):
          // the phone interleaves them with the tool steps in the live feed. Folding
          // them into message.text hid them, because the live body is suppressed.
        } else if (runningEntry) {
          const placeholder = runningPlaceholderMessage(runningEntry);
          if (placeholder) {
            msgs.push(placeholder);
            last = placeholder;
          }
        }
        // The live feed grows by appending progress NODES (a new Read/Edit/Run step or
        // an interior narration "text" node) as well as by the trailing summary text
        // growing. Fold the node count into the dedup signature so each new step
        // re-pushes — keying on text length alone left the feed frozen between the
        // narration paragraphs that bracket a burst of tool calls.
        const sig =
          msgs.length + ":" +
          (last
            ? (last.uid || "") + ":" + String(last.text || "").length +
              ":" + (Array.isArray(last.progressNodes) ? last.progressNodes.length : 0)
            : 0) +
          ":" + (running ? "run" : "done");
        if (sig !== rec.lastSig) {
          rec.lastSig = sig;
          channel.push("history_result", { ok: true, ...echo, ...result });
        }
        // Desktop-terminal runs have no close event to seal the final card. Once the
        // file goes quiet past the live window, fire once more: liveByFile flips false,
        // the trailing turn seals, and the run→done sig change pushes the final state.
        if (rec.settle) { clearTimeout(rec.settle); rec.settle = null; }
        if (liveByFile && !runningEntry && channel.state === "joined") {
          rec.settle = setTimeout(() => { rec.settle = null; fire(); }, LIVE_SESSION_WINDOW_MS + 1500);
        }
      })
      .catch(() => {})
      .finally(() => {
        rec.busy = false;
        if (rec.again) { rec.again = false; schedule(); }
      });
  };
  const schedule = () => {
    if (rec.debounce) return;
    rec.debounce = setTimeout(() => { rec.debounce = null; fire(); }, HISTORY_WATCH_DEBOUNCE_MS);
  };
  rec.schedule = schedule;
  try {
    // Event-based: fires within ms of claude/codex appending to the transcript.
    rec.watcher = fs.watch(file, { persistent: true }, () => schedule());
  } catch (_) {
    // Fallback to polling if fs.watch is unavailable on this filesystem.
    rec.listener = () => schedule();
    fs.watchFile(file, { interval: 1000 }, rec.listener);
  }
  historyWatchers.set(chatId, rec);
  schedule(); // catch anything appended between the initial read and now
}

function handleHistoryRequest(channel, payload) {
  const provider = payload.provider || payload.agentBridgeProvider || "claude";
  const requestId = payload.requestId || payload.request_id || crypto.randomUUID();
  const chatId = payload.chatId || payload.chat_id || null;
  const sessionId = payload.sessionId || payload.session_id || null;
  const echo = { requestId, provider, chatId, requesterUserId: payload.requesterUserId || payload.requester_user_id || null };

  readHistory({ provider, mode: payload.mode, sessionId, limit: payload.limit })
    .then((result) => {
      // Mark the trailing turn live on the FIRST detail push too (not just on watch
      // re-fires) so opening a live session lands directly in the working state with
      // no flash of the sealed "Worked · N steps" card.
      markDetailLiveTurn(result, provider, sessionId, chatId);
      channel.push("history_result", { ok: true, ...echo, ...result });
      // The phone opened a specific session → keep it live by tailing the
      // transcript and re-pushing as it grows.
      if (chatId && sessionId && result.mode === "detail") {
        startHistoryWatch(channel, { chatId, provider, sessionId, echo });
      }
    })
    .catch((err) => {
      channel.push("history_result", { ok: false, ...echo, message: err && err.message ? err.message : "history_failed" });
    });
}

// ── File open (full file contents, on demand) ───────────────────────
// The phone can open a file the agent touched. We read it ONLY when it lives
// inside a linked repository (never an arbitrary path), cap the size, and seal
// the bytes with the runtime key so the server relays an opaque blob — the
// user's source code never reaches the server in the clear.
const MAX_FILE_BYTES = 2 * 1024 * 1024;

function fileWithinLinkedRepo(absPath) {
  const dir = realDir(path.dirname(absPath));
  if (!dir) return null;
  const full = path.join(dir, path.basename(absPath));
  const inside = ADVERTISED_REPOSITORIES.some((repo) => {
    const root = realDir(repo.cwd || repo.path);
    return root && (full === root || full.startsWith(root + path.sep));
  });
  return inside ? full : null;
}

function handleFileRequest(channel, payload) {
  const requestId = payload.requestId || payload.request_id || crypto.randomUUID();
  const chatId = payload.chatId || payload.chat_id || null;
  const provider = payload.provider || payload.agentBridgeProvider || "claude";
  const rawPath = String(payload.path || payload.file || payload.filePath || "").trim();
  const echo = { requestId, chatId, provider, path: rawPath };
  try {
    if (!rawPath) throw new Error("missing path");
    const absPath = path.resolve(expandHome(rawPath) || rawPath);
    const safePath = fileWithinLinkedRepo(absPath);
    if (!safePath) throw new Error("that file is outside your linked repositories");
    const stat = fs.statSync(safePath);
    if (!stat.isFile()) throw new Error("not a file");
    let truncated = false;
    let content;
    if (stat.size > MAX_FILE_BYTES) {
      const fd = fs.openSync(safePath, "r");
      const buf = Buffer.alloc(MAX_FILE_BYTES);
      const read = fs.readSync(fd, buf, 0, MAX_FILE_BYTES, 0);
      fs.closeSync(fd);
      content = buf.slice(0, read).toString("utf8");
      truncated = true;
    } else {
      content = fs.readFileSync(safePath, "utf8");
    }
    const enc = encryptRuntimeBlob({
      path: safePath,
      name: path.basename(safePath),
      content,
      truncated,
      size: stat.size,
    });
    if (!enc) throw new Error("encryption key not ready — sync it from the bridge (--show-key)");
    channel.push("file_result", { ok: true, ...echo, agentFileEnc: enc, truncated, size: stat.size });
  } catch (err) {
    channel.push("file_result", { ok: false, ...echo, message: (err && err.message) || "file_failed" });
  }
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

// Called on every successful (re)join. On the FIRST join `socketDownSince` is null so
// this is a no-op; on a REJOIN after a drop it (1) re-delivers any result that completed
// while the socket was down — whose one-shot push was lost, leaving the phone's live
// clock ticking forever until an app restart — and (2) re-arms the history watches the
// drop tore down, so the transcript re-syncs in place. The finishedAt >= socketDownSince
// window means only results that were NOT delivered get re-sent (no duplicates).
function recoverAfterReconnect(channel) {
  if (socketDownSince == null) return;
  const downMs = Date.now() - socketDownSince;
  let redelivered = 0;
  for (const rec of finishedTasks.values()) {
    if (rec && rec.resultPayload && rec.finishedAt >= socketDownSince) {
      try {
        channel.push("result", rec.resultPayload);
        redelivered++;
      } catch (_) {}
    }
  }
  let rewatched = 0;
  for (const [chatId, spec] of historyWatchSpecs.entries()) {
    try {
      startHistoryWatch(channel, { chatId, ...spec });
      rewatched++;
    } catch (_) {}
  }
  console.log(
    `[vibe-bridge] reconnected after ${downMs}ms down — recovery: redelivered=${redelivered} result(s), rewatched=${rewatched} chat(s)`
  );
  socketDownSince = null;
}

function connect(server, token, userId) {
  const socket = new Phoenix.Socket(wsUrl(server), {
    params: { token },
    transport: WebSocket,
    reconnectAfterMs: (tries) => [1000, 2000, 5000, 10000][tries - 1] || 10000,
    // A tighter heartbeat keeps idle connections alive through proxy/LB idle reapers
    // (the recurring code=1006 drops) and detects a dead socket faster so the auto
    // reconnect kicks in sooner.
    heartbeatIntervalMs: 15000,
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
    // Mark the start of the outage (first close only) so the rejoin handler can recover
    // anything that completed while we were down.
    if (socketDownSince == null) socketDownSince = Date.now();
    stopAllHistoryWatches(); // watchers hold a now-stale channel
  });
  socket.connect();

  const channel = socket.channel(`bridge:${userId}`, {});
  channel.on("run_task", (task) =>
    runTask(channel, task).catch((err) =>
      console.error(`[vibe-bridge] runTask error: ${(err && err.message) || err}`)
    )
  );
  channel.on("control_task", (payload) => controlTask(channel, payload || {}));
  channel.on("history_request", (payload) => handleHistoryRequest(channel, payload || {}));
  channel.on("file_request", (payload) => handleFileRequest(channel, payload || {}));

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
      recoverAfterReconnect(channel);
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
  ensureRuntimeKey(config);
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
    runTask(channel, task).catch((err) =>
      console.error(`[vibe-bridge] runTask error: ${(err && err.message) || err}`)
    );
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
        ...teamFieldsForTask(stepObject),
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
      ...teamFieldsForTask(ARGS),
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
	        "     VIBE_CODEX_APPROVAL_POLICY, VIBE_CLAUDE_MODEL, VIBE_CODEX_MODEL,\n" +
	        "     VIBE_CLAUDE_COMMAND, VIBE_CODEX_COMMAND"
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

// Exposed for local tests (history runtime reconstruction). Harmless at runtime.
module.exports = {
  claudeDetail,
  codexDetail,
  buildHistoryRuntime,
  collectClaudeEdits,
	  collectCodexEdits,
	  parseApplyPatchEnvelope,
	  newRuntimeAccumulator,
	  ensureRuntimeKey,
	  liveAgentActionsField,
	  liveClaudeActions,
	  liveCodexActions,
	  fileWithinLinkedRepo,
	  handleFileRequest,
	  normalizeModel,
	  runningPlaceholderMessage,
	};

// Only auto-run the daemon when invoked directly (so the module is requireable).
if (require.main === module) {
  main().catch((err) => {
    console.error("[vibe-bridge] fatal:", err.message);
    process.exit(1);
  });
}
