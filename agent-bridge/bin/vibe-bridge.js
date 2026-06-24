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
 *   npx vibe-bridge --code <PAIRING_CODE> --server https://your-vibe-server
 *   # subsequent runs (token cached in ~/.vibe/bridge.json):
 *   npx vibe-bridge --server https://your-vibe-server
 *
 * Safety: defaults to read-only execution (claude --permission-mode plan,
 * codex --sandbox read-only). Escalate explicitly via the env vars below.
 */

const fs = require("fs");
const os = require("os");
const path = require("path");
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
  const out = {};
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--code") out.code = argv[++i];
    else if (a === "--server") out.server = argv[++i];
    else if (a === "--cwd") out.cwd = argv[++i];
    else if (a === "--label") out.label = argv[++i];
    else if (a === "--logout") out.logout = true;
    else if (a === "-h" || a === "--help") out.help = true;
  }
  return out;
}

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

// ── Running claude / codex ──────────────────────────────────────────

const sessionByChat = new Map(); // chatId -> claude session_id

function stripReservedMention(prompt, provider) {
  return String(prompt || "")
    .replace(new RegExp(`(^|\\s)@${provider}\\b`, "ig"), " ")
    .trim();
}

function buildCommand(provider, prompt, chatId) {
  const cleaned = stripReservedMention(prompt, provider);
  if (provider === "claude") {
    const mode = process.env.VIBE_CLAUDE_PERMISSION_MODE || "plan";
    const args = ["-p", "--output-format", "stream-json", "--permission-mode", mode];
    const sid = sessionByChat.get(chatId);
    if (sid) args.push("--resume", sid);
    args.push("--verbose");
    if (process.env.VIBE_CLAUDE_MODEL) args.push("--model", process.env.VIBE_CLAUDE_MODEL);
    args.push("--", cleaned);
    return { cmd: process.env.VIBE_CLAUDE_COMMAND || "claude", args };
  }
  if (provider === "codex") {
    const sandbox = process.env.VIBE_CODEX_SANDBOX || "read-only";
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
  const built = buildCommand(provider, prompt, chatId);
  if (!built) {
    channel.push("error", { provider, chatId, message: `Unknown provider: ${provider}` });
    return;
  }

  const cwd = ARGS.cwd || process.cwd();
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
    .receive("ok", () => console.log(`[vibe-bridge] connected — computer online for user ${userId}`))
    .receive("error", (e) => console.error("[vibe-bridge] join error:", JSON.stringify(e)));

  // Lightweight heartbeat to keep last_seen fresh (socket also heartbeats).
  setInterval(() => {
    if (channel.state === "joined") channel.push("heartbeat", {});
  }, 30000);
}

// ── Main ────────────────────────────────────────────────────────────

const ARGS = parseArgs(process.argv);

async function main() {
  if (ARGS.help) {
    console.log(
      "Usage: vibe-bridge --code <PAIRING_CODE> --server <https://vibe-server>\n" +
        "       vibe-bridge --server <https://vibe-server>   (uses cached token)\n" +
        "       vibe-bridge --logout\n\n" +
        "Env: VIBE_CLAUDE_PERMISSION_MODE (default plan), VIBE_CODEX_SANDBOX (default read-only),\n" +
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
  const server = normalizeServer(ARGS.server || config.server);
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
    console.error(
      "[vibe-bridge] Not paired. Open Claude or Codex in the Vibe app, tap Connect, and run this with --code <CODE>."
    );
    process.exit(1);
  }

  // Persist latest server if changed.
  if (config.server !== server) saveConfig({ server, bridge_token: token, user_id: userId });

  connect(server, token, userId);
}

main().catch((err) => {
  console.error("[vibe-bridge] fatal:", err.message);
  process.exit(1);
});
