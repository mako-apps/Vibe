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

// ---------- built-in safe Bash allow-list (read / search / inspect / build) ---
// Read-only, non-mutating commands that never need a human. Evaluated PER PIPELINE
// SEGMENT so "grep foo | head", "cat f | sort | uniq -c", "find . | wc -l" all pass.
const SAFE_BASH = [
  /^(ls|pwd|cat|bat|head|tail|less|more|wc|file|stat|du|df|tree|basename|dirname|realpath|readlink)\b/,
  /^(grep|egrep|fgrep|rg|ag|ack|find|fd|which|type|whereis|locate|mdfind)\b/,
  /^(echo|printf|true|false|date|whoami|hostname|uname|env|sw_vers|sleep|id|groups|uptime|arch|yes)\b/,
  /^(sed|awk|cut|sort|uniq|tr|nl|column|comm|join|paste|rev|fold|fmt|tac|xxd|od|strings|hexdump|base64)\b/,
  /^(jq|yq|xmllint|plutil\s+-(p|lint))\b/,
  /^(diff|cmp|colordiff)\b/,
  /^(ps|top\s+-l|lsof|pgrep|vm_stat|sysctl\s+-[na])\b/,
  /^git\s+(status|diff|log|show|branch|remote|blame|rev-parse|rev-list|describe|ls-files|ls-tree|cat-file|shortlog|reflog|stash\s+list|tag(\s+-l|\s+--list)?|for-each-ref|show-ref|show-branch|name-rev|merge-base|count-objects|config\s+--(get|list)|whatchanged|grep)\b/,
  /^(node|npm|npx|yarn|pnpm|bun)\s+(--version|-v|list|ls|why|outdated|view|info|run\s+lint|run\s+test|test)\b/,
  /^(python3?|pip3?|ruby|gem|cargo|go|rustc|java|javac|kotlin|clang|gcc|deno)\s+(--version|-v|version|--help|-h)\b/,
  /^(cargo|go)\s+(check|vet|fmt\s+--check|clippy)\b/,
  /^(xcodebuild|swift|swiftc)\b[^\n]*\bbuild\b/,                    // building is free
  /^xcodebuild\s+(-list|-showsdks|-showBuildSettings|-version)\b/,
  /^xcrun\s+(simctl|xctrace|devicectl)\s+(list|help)\b/,           // querying devices is free
  /^xcrun\s+(--find|--sdk|--show-sdk-path|--version)\b/,
  /^(cd|pushd|popd)\b/,                                             // navigation only
  // building / compiling / running the project's own build+test scripts is free —
  // it only produces artifacts under the repo (never installs deps or touches git).
  /^make\s+.*\b(build|test|check|lint|all)\b/,                     // bare "make" (default target) still asks
  /^(cargo)\s+(build|test|run)\b/,
  /^go\s+(build|test|run)\b/,
  /^(tsc|webpack|vite|rollup|esbuild|parcel)\b/,
  /^(gradle|gradlew|\.\/gradlew)\s+(build|test|assemble|check)\b/,
  /^mvn\b[^\n]*\b(compile|test|package|verify)\b/,
  /^(node|npm|npx|yarn|pnpm|bun)\s+(run\s+)?(build|dev|start|test|typecheck|type-check|lint)\b/,
  /^swift\s+test\b/,
  // read-only network fetch — no upload, no piping into a shell (those are still
  // caught by MUTATING / DANGEROUS below).
  /^curl\b/, /^wget\b/, /^http(ie)?\b/,
];
// A segment matching any of these is treated as NOT safe (asks a human) even if a
// SAFE_BASH prefix also matched — these mutate the filesystem / state.
const MUTATING = [
  /\bsed\b[^|;&]*\s-i\b/, /\bperl\b[^|;&]*\s-i\b/, /\btee\b/, /\btruncate\b/,
  /\b(mv|cp|rm|mkdir|rmdir|touch|ln|chmod|chown|chgrp|install|unlink)\b/,
  /\bgit\s+(add|commit|checkout|reset|rebase|merge|pull|fetch|clone|apply|am|mv|rm|restore|switch|cherry-pick|revert|push|clean|init|tag\s+(?!-l|--list))\b/,
  /\b(npm|yarn|pnpm|bun)\s+(install|i|ci|add|remove|uninstall|update|upgrade|link|publish)\b/,
  /\bpip3?\s+(install|uninstall)\b/, /\b(gem|cargo|go)\s+(install|publish)\b/,
  /\bdefaults\s+write\b/, /\blaunchctl\b/, /\bkill(all)?\b/, /\bpkill\b/,
  />{1,2}(?!\s*\/dev\/null)/, // output redirect that writes to a file
  /\bcurl\b[^|;&\n]*(-o\b|--output\b|-O\b|--remote-name\b|-X\s*(POST|PUT|PATCH|DELETE)|--upload-file)/i,
  /\bwget\b[^|;&\n]*(-O\b|--output-document\b)/i,
];

// Mask quoted regions (keep length) so a pipe/`&&` INSIDE quotes — e.g. grep -E 'a|b'
// — is not mistaken for a pipeline separator.
function maskQuotes(s) {
  let out = "", q = null;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (q) { out += (c === q ? c : "X"); if (c === q) q = null; }
    else if (c === '"' || c === "'" || c === "`") { q = c; out += c; }
    else out += c;
  }
  return out;
}
function splitSegments(cmd) {
  const masked = maskQuotes(cmd);
  const re = /\|\||&&|;|\||\n/g;
  const segs = []; let start = 0, m;
  while ((m = re.exec(masked))) { segs.push(cmd.slice(start, m.index)); start = m.index + m[0].length; }
  segs.push(cmd.slice(start));
  return segs.map((x) => x.trim()).filter((x) => x.length);
}
function segmentIsSafe(seg, cfg) {
  if (!seg) return true;
  if (/\$\(|`|<\(/.test(maskQuotes(seg))) return false; // command / process substitution
  if (MUTATING.some((re) => re.test(seg))) return false;
  if (SAFE_BASH.some((re) => re.test(seg))) return true;
  for (const p of cfg.auto_allow) { if (p && seg.includes(p)) return true; }
  return false;
}
function bashIsAutoSafe(cmd, cfg) {
  // user auto_allow substrings may match the whole command (e.g. "xcrun simctl ...")
  for (const p of cfg.auto_allow) { if (p && cmd.includes(p)) return true; }
  const segs = splitSegments(cmd);
  return segs.length > 0 && segs.every((seg) => segmentIsSafe(seg, cfg));
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

  // 3) AskUserQuestion: only force the phone (deny native + redirect to the MCP tool)
  //    in "mobile" mode. In auto/both/full the desk is present, so let Claude's native
  //    in-app question render HERE — don't shove every question to the phone.
  if (toolName === "AskUserQuestion") {
    if (mode !== "mobile") return passthrough(); // native question at the desk
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
