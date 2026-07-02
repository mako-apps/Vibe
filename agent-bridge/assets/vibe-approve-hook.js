#!/usr/bin/env node
"use strict";
// Vibe PreToolUse hook — decides how Claude Code gets approval for tools.
// Behaviour is driven by ~/.vibe/agent-config.toml (approval_mode):
//   "local"  -> pure pass-through: approve/answer on THIS device only (no phone).
//   "mobile" -> safe/allow-listed run w/o asking; blockers -> phone (falls back to
//               a local prompt after 3 min / if the bridge is down, so nothing hangs).
//   "auto"   -> same as "mobile" (Codex-like: safe auto, blockers -> phone).
//   "both"   -> safe/allow-listed run w/o asking; blockers show on BOTH the desk and
//               the phone at once (first responder wins) when this is a real terminal
//               session; a headless/IDE session (no /dev/tty) just prompts locally so
//               the agent never blocks on the phone.
//   "full"   -> allow everything EXCEPT the always-blocked dangerous list.
// The always-blocked dangerous list is enforced in every mode except "local".
const fs = require("fs");
const net = require("net");
const os = require("os");
const path = require("path");
const tty = require("tty");
const HOME = os.homedir();
const VDIR = path.join(HOME, ".vibe");
const SOCK = path.join(VDIR, "ask.sock");
const CONFIG_PATH = path.join(VDIR, "agent-config.toml");
const ROUTE_TIMEOUT_MS = 180000;

// ---------- tiny TOML subset reader (key = value / ["a","b"] / true|false) ----
function parseToml(text) {
  const out = {};
  for (const line of text.split(/\r?\n/)) {
    const t = line.trim();
    if (!t || t.startsWith("#") || t.startsWith("[")) continue;
    const eq = t.indexOf("=");
    if (eq < 0) continue;
    const key = t.slice(0, eq).trim();
    let val = t.slice(eq + 1).trim();
    if (val.startsWith("[")) {
      const inner = val.replace(/^\[/, "").replace(/\][^\]]*$/, "");
      out[key] = inner.split(",").map((s) => s.trim().replace(/^["']|["']$/g, "")).filter(Boolean);
    } else if (val === "true" || val === "false") {
      out[key] = val === "true";
    } else {
      out[key] = val.replace(/\s+#.*$/, "").trim().replace(/^["']|["']$/g, "");
    }
  }
  return out;
}
function readConfig() {
  const cfg = { approval_mode: "local", auto_allow: [], deny: [] };
  try { Object.assign(cfg, parseToml(fs.readFileSync(CONFIG_PATH, "utf8"))); } catch (_) {}
  if (!Array.isArray(cfg.auto_allow)) cfg.auto_allow = [];
  if (!Array.isArray(cfg.deny)) cfg.deny = [];
  return cfg;
}

// ---------- always-blocked (destructive) — never auto, denied even in full ----
const DANGEROUS = [
  /\brm\s+-\w*[rf]/, /\bsudo\b/, /\bgit\s+push\b/, /\bgit\s+reset\s+--hard\b/,
  /\bgit\s+clean\b/, /\bmkfs\b/, /\bdd\s+if=/, /:\s*\(\s*\)\s*\{/, /\bshutdown\b/,
  /\breboot\b/, /\bkillall\b/, /\bchmod\s+-R\s+777\b/, />\s*\/dev\/sd/,
  /--force\b.*\bpush\b|\bpush\b.*--force\b/, /\bnpm\s+publish\b/,
  /\bcurl\b[^\n]*\|\s*(sh|bash|zsh)\b/, /\bwget\b[^\n]*\|\s*(sh|bash|zsh)\b/,
];
function isDangerous(cmd) { return DANGEROUS.some((re) => re.test(cmd)); }

// ---------- built-in safe Bash allow-list (read / search / build) -------------
const SAFE_BASH = [
  /^(ls|pwd|cat|head|tail|less|wc|file|stat|du|df|tree|basename|dirname|realpath)\b/,
  /^(grep|rg|ag|ack|find|fd|which|type|whereis|locate)\b/,
  /^(echo|printf|true|false|date|whoami|hostname|uname|env|sw_vers|sleep)\b/,
  /^git\s+(status|diff|log|show|branch|remote|blame|rev-parse|describe|ls-files|shortlog|config\s+--get)\b/,
  /^(node|npm|npx|yarn|pnpm)\s+(--version|-v|list|ls|why|outdated|run\s+lint|run\s+test|test)\b/,
  /^(xcodebuild|swift|swiftc)\b[^\n]*\bbuild\b/,          // building is free
  /^xcrun\s+(simctl|xctrace|devicectl)\s+(list|help)\b/,  // querying devices is free
];
const CHAINY = /(;|&&|\|\||\$\(|`)/; // could chain past an allow-listed prefix
function bashIsAutoSafe(cmd, cfg) {
  if (CHAINY.test(cmd)) return false;
  if (SAFE_BASH.some((re) => re.test(cmd.trim()))) return true;
  for (const p of cfg.auto_allow) { if (p && cmd.includes(p)) return true; }
  return false;
}

// ---------- output helpers ----------------------------------------------------
function emit(decision, reason, updatedInput) {
  const hso = { hookEventName: "PreToolUse", permissionDecision: decision };
  if (reason) hso.permissionDecisionReason = reason;
  if (updatedInput) hso.updatedInput = updatedInput;
  process.stdout.write(JSON.stringify({ hookSpecificOutput: hso }));
  process.exit(0);
}
function passthrough() { process.exit(0); } // no output -> Claude's normal permission flow

function jobLabel(toolName, input) {
  if (toolName === "Bash") return "run  " + String(input.command || "").replace(/\s+/g, " ").slice(0, 200);
  if (toolName === "Edit" || toolName === "Write" || toolName === "MultiEdit" || toolName === "NotebookEdit")
    return toolName + "  " + (input.file_path || input.notebook_path || "");
  return toolName;
}

// ---------- open the controlling terminal, if this is a real tty session ------
function openTty() {
  try {
    const fd = fs.openSync("/dev/tty", "r+");
    if (!tty.isatty(fd)) { try { fs.closeSync(fd); } catch (_) {} return -1; }
    return fd;
  } catch (_) { return -1; }
}

// ---------- phone-only routing (mobile/auto modes, or "both" without a tty) ----
function routeToPhone(job, timeoutMs) {
  let done = false;
  const finish = (fn) => { if (!done) { done = true; fn(); } };
  const timer = setTimeout(() => finish(() => emit("ask", "Vibe: no response from your phone — approve here.")), timeoutMs || ROUTE_TIMEOUT_MS);
  if (timer.unref) timer.unref();
  let buf = "";
  const conn = net.createConnection(SOCK, () => {
    conn.write(JSON.stringify({ type: "command", cwd: job.cwd, source: "hook", sessionId: job.sessionId || "", tool_name: job.toolName, input: job.input }) + "\n");
  });
  conn.setEncoding("utf8");
  conn.on("data", (d) => {
    buf += d; const nl = buf.indexOf("\n"); if (nl < 0) return;
    let parsed = null; try { parsed = JSON.parse(buf.slice(0, nl)); } catch (_) {}
    try { conn.end(); } catch (_) {}
    clearTimeout(timer);
    const ans = (parsed && parsed.answer) || {};
    const decision = String(ans.decision || ans.action || "").toLowerCase();
    if (decision === "approve" || decision === "allow") finish(() => emit("allow", ans.message || "Approved from phone.", ans.updatedInput));
    else if (decision === "deny" || decision === "skip") finish(() => emit("deny", ans.message || (decision === "skip" ? "Skipped from your phone." : "Denied from your phone.")));
    else finish(() => emit("ask", "Vibe: no clear decision — approve here."));
  });
  conn.on("error", () => { clearTimeout(timer); finish(() => emit("ask", "Vibe bridge unreachable — approve here.")); });
  conn.on("close", () => { clearTimeout(timer); finish(() => emit("ask", "Vibe: connection closed — approve here.")); });
}

// ---------- BOTH: race the desk (/dev/tty keypress) and the phone -------------
// First responder wins. If the phone is unreachable we keep waiting on the desk;
// if there's no tty at all the caller uses routeToPhone / a local prompt instead.
function raceDeskAndPhone(job, ttyFd) {
  let done = false;
  let ttyIn = null, conn = null;
  const cleanup = () => {
    try { if (ttyIn) { ttyIn.setRawMode(false); ttyIn.pause(); ttyIn.destroy(); } } catch (_) {}
    try { fs.closeSync(ttyFd); } catch (_) {}
    try { if (conn) conn.destroy(); } catch (_) {}
  };
  const finish = (decision, reason, updatedInput) => {
    if (done) return; done = true;
    if (decision === "allow" || decision === "deny") {
      try { fs.writeSync(ttyFd, `\r\n\x1b[36m[Vibe]\x1b[0m ${decision === "allow" ? "approved" : "denied"}\r\n`); } catch (_) {}
    }
    cleanup();
    emit(decision, reason, updatedInput);
  };

  // desk side
  try { fs.writeSync(ttyFd, `\r\n\x1b[36m[Vibe]\x1b[0m approve  ${job.label}\r\n  \x1b[32my\x1b[0m = allow   \x1b[31mn\x1b[0m = deny   (or answer on your phone)\r\n`); } catch (_) {}
  try {
    ttyIn = new tty.ReadStream(ttyFd);
    ttyIn.setRawMode(true);
    ttyIn.setEncoding("utf8");
    ttyIn.on("data", (s) => {
      const ch = String(s).toLowerCase();
      if (ch.indexOf("y") >= 0) finish("allow", "Approved at the desk.");
      else if (ch.indexOf("n") >= 0) finish("deny", "Denied at the desk.");
      else if (ch === "\x03" || ch === "\x1b") finish("deny", "Cancelled at the desk.");
    });
    ttyIn.on("error", () => {});
  } catch (_) {}

  // phone side
  let buf = "";
  conn = net.createConnection(SOCK, () => {
    conn.write(JSON.stringify({ type: "command", cwd: job.cwd, source: "hook-both", sessionId: job.sessionId || "", tool_name: job.toolName, input: job.input }) + "\n");
  });
  conn.setEncoding("utf8");
  conn.on("data", (d) => {
    buf += d; const nl = buf.indexOf("\n"); if (nl < 0) return;
    let parsed = null; try { parsed = JSON.parse(buf.slice(0, nl)); } catch (_) {}
    const ans = (parsed && parsed.answer) || {};
    const decision = String(ans.decision || ans.action || "").toLowerCase();
    if (decision === "approve" || decision === "allow") finish("allow", ans.message || "Approved from phone.", ans.updatedInput);
    else if (decision === "deny" || decision === "skip") finish("deny", ans.message || (decision === "skip" ? "Skipped from your phone." : "Denied from your phone."));
  });
  // phone gone: don't give up — the desk can still answer.
  conn.on("error", () => {});
  conn.on("close", () => {});

  const timer = setTimeout(() => finish("ask", "Vibe: no response — approve here."), ROUTE_TIMEOUT_MS);
  if (timer.unref) timer.unref();
}

// ---------- main --------------------------------------------------------------
let raw = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (d) => { raw += d; });
process.stdin.on("end", () => {
  let ev = null; try { ev = JSON.parse(raw); } catch (_) {}
  if (!ev) return passthrough();

  // Bridge-spawned runs already gate via --permission-prompt-tool; don't double up.
  if (process.env.VIBE_ASK_CHAT) return passthrough();

  const cfg = readConfig();
  const mode = String(cfg.approval_mode || "local").toLowerCase();
  const toolName = ev.tool_name || "";
  const input = ev.tool_input || {};
  const cwd = ev.cwd || process.cwd();
  const cmd = toolName === "Bash" ? String(input.command || "") : "";

  // 1) LOCAL: approve/answer on this device only. Pure pass-through.
  if (mode === "local") return passthrough();

  // 2) Always-blocked destructive commands (denied even in full access).
  if (cmd && isDangerous(cmd)) {
    return emit("deny", "Vibe: this command is on the always-blocked list (destructive) — not allowed even in full access.");
  }
  if (cmd && cfg.deny.some((p) => p && cmd.includes(p))) {
    return emit("deny", "Vibe: this command matches your configured deny list.");
  }

  // 3) AskUserQuestion: deny native + redirect to the MCP tool that reaches the
  //    phone (when the bridge is up); otherwise fall back to the native local prompt.
  if (toolName === "AskUserQuestion") {
    const probe = net.createConnection(SOCK, () => {
      try { probe.end(); } catch (_) {}
      emit("deny", "Use the mcp__vibeask__ask_user tool instead — it delivers your question to the user's phone and returns their answer. Do not use AskUserQuestion here.");
    });
    probe.on("error", () => passthrough());
    return;
  }

  // 4) auto-allow: read-only tools + safe/allow-listed Bash run without asking.
  const readOnly = ["Read", "Glob", "Grep", "NotebookRead", "TodoWrite"].includes(toolName);
  const isEdit = ["Edit", "Write", "MultiEdit", "NotebookEdit"].includes(toolName);
  if (readOnly || isEdit || (toolName === "Bash" && bashIsAutoSafe(cmd, cfg))) {
    return emit("allow", "Vibe auto-approved (safe / allow-listed).");
  }

  // 5) full access: allow everything else (dangerous already denied above).
  if (mode === "full") return emit("allow", "Vibe full-access.");

  // 6) blockers need a human.
  const job = { toolName, input, cwd, sessionId: ev.session_id, label: jobLabel(toolName, input) };
  if (mode === "both") {
    const ttyFd = openTty();
    if (ttyFd >= 0) return raceDeskAndPhone(job, ttyFd); // desk + phone, first wins
    // headless (IDE): a hook can't race Claude's native prompt (returning "ask" ends the
    // hook), so give the phone a short window, then fall back to the native in-app ask.
    return routeToPhone(job, 15000);
  }
  // mobile / auto -> phone with local fallback.
  return routeToPhone(job);
});
