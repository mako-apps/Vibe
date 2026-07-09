"use strict";

/**
 * Google Antigravity CLI (`agy`) bridge helpers.
 *
 * Headless: `agy -p <prompt> [--conversation id] [--model …] [--mode …]
 *           [--dangerously-skip-permissions]`
 * stdout is plain final text only. Full payload (thinking, tools, narration)
 * lives in `~/.gemini/antigravity-cli/brain/<conversationId>/.system_generated/logs/transcript.jsonl`.
 * Session index: conversation_summaries.db + history.jsonl + last_conversations.json.
 */

const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");

const AGY_DETAIL_MIDTURN_STALE_MS = Number(
  process.env.VIBE_AGY_DETAIL_MIDTURN_STALE_MS || 30_000
);

// How far before the run's start a transcript step may be dated and still count as
// part of THIS run (guards the live tail against replaying prior turns from a reused
// conversation file — see the created_at filter in startAgyTranscriptTail).
const AGY_TAIL_STEP_SKEW_MS = Number(
  process.env.VIBE_AGY_TAIL_STEP_SKEW_MS || 15_000
);

function agyHome() {
  if (process.env.VIBE_AGY_HOME) return process.env.VIBE_AGY_HOME;
  return path.join(os.homedir(), ".gemini", "antigravity-cli");
}

function agyConversationsDir() {
  return path.join(agyHome(), "conversations");
}

function agyBrainDir(conversationId) {
  return path.join(agyHome(), "brain", conversationId);
}

function agyTranscriptPath(conversationId) {
  return path.join(
    agyBrainDir(conversationId),
    ".system_generated",
    "logs",
    "transcript.jsonl"
  );
}

function agyTranscriptFullPath(conversationId) {
  return path.join(
    agyBrainDir(conversationId),
    ".system_generated",
    "logs",
    "transcript_full.jsonl"
  );
}

function agySummariesDbPath() {
  return path.join(agyHome(), "conversation_summaries.db");
}

function agyLastConversationsPath() {
  return path.join(agyHome(), "cache", "last_conversations.json");
}

function agyHistoryPath() {
  return path.join(agyHome(), "history.jsonl");
}

function isEphemeralProject(p) {
  return /(^|\/)(private\/)?tmp(\/|$)/.test(p) || /vibe-(bridge|agent)-/.test(p) || /self-test/.test(p);
}

function readJsonSafe(file) {
  try {
    if (!fs.existsSync(file)) return null;
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return null;
  }
}

function workspaceFromUris(raw) {
  if (!raw) return "";
  if (Array.isArray(raw)) {
    const first = raw[0];
    if (typeof first === "string") return first.replace(/^file:\/\//, "");
    return "";
  }
  if (typeof raw === "string") {
    try {
      const parsed = JSON.parse(raw);
      if (Array.isArray(parsed) && parsed[0]) {
        return String(parsed[0]).replace(/^file:\/\//, "");
      }
    } catch {
      /* fall through */
    }
    // Often a single path or comma-joined
    const first = raw.split(",")[0].trim().replace(/^file:\/\//, "").replace(/^"|"$/g, "");
    return first;
  }
  return "";
}

function listAgySessionsFromFs() {
  const dir = agyConversationsDir();
  const out = [];
  if (!fs.existsSync(dir)) return out;
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return out;
  }
  for (const ent of entries) {
    if (!ent.isFile() && !ent.isDirectory()) continue;
    const name = ent.name;
    if (!name.endsWith(".db")) continue;
    if (name.includes("-wal") || name.includes("-shm")) continue;
    const id = name.replace(/\.db$/, "");
    const dbPath = path.join(dir, name);
    let st;
    try {
      st = fs.statSync(dbPath);
    } catch {
      continue;
    }
    const transcript = agyTranscriptPath(id);
    const transcriptFull = agyTranscriptFullPath(id);
    let tMtime = st.mtimeMs;
    let tSize = st.size;
    for (const p of [transcript, transcriptFull]) {
      try {
        const ts = fs.statSync(p);
        if (ts.mtimeMs > tMtime) tMtime = ts.mtimeMs;
        tSize = Math.max(tSize, ts.size);
      } catch {
        /* optional */
      }
    }
    out.push({
      id,
      file: fs.existsSync(transcript) ? transcript : transcriptFull,
      dbFile: dbPath,
      project: "",
      mtime: tMtime,
      size: tSize,
    });
  }
  return out;
}

function readSummariesRows() {
  const dbPath = agySummariesDbPath();
  if (!fs.existsSync(dbPath)) return [];
  try {
    // System sqlite3 CLI — no extra npm dependency.
    const sql =
      "SELECT conversation_id, title, preview, step_count, last_modified_time, " +
      "workspace_uris, status, project_id, last_user_input_time " +
      "FROM conversation_summaries;";
    const out = execFileSync("sqlite3", ["-json", dbPath, sql], {
      encoding: "utf8",
      maxBuffer: 8 * 1024 * 1024,
      timeout: 5000,
    });
    const rows = JSON.parse(out || "[]");
    return Array.isArray(rows) ? rows : [];
  } catch {
    return [];
  }
}

function enrichSessionsFromSummaries(sessions) {
  const rows = readSummariesRows();
  if (!rows.length) return sessions;
  const byId = new Map(rows.map((r) => [r.conversation_id, r]));
  for (const s of sessions) {
    const row = byId.get(s.id);
    if (!row) continue;
    s.topic = row.title || row.preview || s.topic || null;
    s.messages = Number(row.step_count || 0) || s.messages || 0;
    s.project = workspaceFromUris(row.workspace_uris) || s.project || "";
    s.lastTs = row.last_modified_time || row.last_user_input_time || s.lastTs || null;
    s.status = row.status || "";
    if (row.last_modified_time) {
      const t = Date.parse(row.last_modified_time);
      if (Number.isFinite(t) && t > s.mtime) s.mtime = t;
    }
  }
  for (const row of rows) {
    if (sessions.some((s) => s.id === row.conversation_id)) continue;
    const project = workspaceFromUris(row.workspace_uris);
    if (isEphemeralProject(project || "")) continue;
    const transcript = agyTranscriptPath(row.conversation_id);
    if (!fs.existsSync(transcript) && !fs.existsSync(agyTranscriptFullPath(row.conversation_id))) {
      continue;
    }
    sessions.push({
      id: row.conversation_id,
      file: fs.existsSync(transcript) ? transcript : agyTranscriptFullPath(row.conversation_id),
      dbFile: path.join(agyConversationsDir(), `${row.conversation_id}.db`),
      project,
      mtime: Date.parse(row.last_modified_time) || Date.now(),
      size: 0,
      topic: row.title || row.preview || null,
      messages: Number(row.step_count || 0) || 1,
      lastTs: row.last_modified_time || null,
      status: row.status || "",
    });
  }
  return sessions;
}

function enrichProjectsFromHistory(sessions) {
  const hist = agyHistoryPath();
  if (!fs.existsSync(hist)) return sessions;
  const byId = new Map(sessions.map((s) => [s.id, s]));
  try {
    const text = fs.readFileSync(hist, "utf8");
    for (const line of text.split("\n")) {
      if (!line.trim()) continue;
      let ev;
      try {
        ev = JSON.parse(line);
      } catch {
        continue;
      }
      if (!ev || !ev.conversationId) continue;
      const s = byId.get(ev.conversationId);
      if (!s) continue;
      if (!s.project && ev.workspace) s.project = String(ev.workspace);
      if (!s.topic && ev.display && !ev.type) {
        const d = String(ev.display).trim();
        if (d && !d.startsWith("/")) s.topic = d.slice(0, 80);
      }
    }
  } catch {
    /* */
  }
  return sessions;
}

function agySessionFiles() {
  let sessions = listAgySessionsFromFs();
  sessions = enrichSessionsFromSummaries(sessions);
  sessions = enrichProjectsFromHistory(sessions);
  return sessions.filter((s) => !isEphemeralProject(s.project || ""));
}

function findAgyConversationForCwd(cwd, afterMs) {
  const real = (() => {
    try {
      return fs.realpathSync(cwd || process.cwd());
    } catch {
      return cwd || process.cwd();
    }
  })();
  // Prefer last_conversations.json when present.
  const last = readJsonSafe(agyLastConversationsPath()) || {};
  for (const [ws, id] of Object.entries(last)) {
    try {
      const rws = fs.realpathSync(ws);
      if (rws === real && id) return String(id);
    } catch {
      if (ws === real || ws === cwd) return String(id);
    }
  }
  // Newest conversation whose project matches cwd, or newest after spawn.
  const files = agySessionFiles()
    .filter((s) => {
      if (afterMs && s.mtime < afterMs - 2000) return false;
      if (!s.project) return !!afterMs;
      try {
        return fs.realpathSync(s.project) === real;
      } catch {
        return s.project === cwd || s.project === real;
      }
    })
    .sort((a, b) => b.mtime - a.mtime);
  return files[0] ? files[0].id : null;
}

function loadTranscriptSteps(conversationId) {
  const primary = agyTranscriptPath(conversationId);
  const full = agyTranscriptFullPath(conversationId);
  const file = fs.existsSync(full) ? full : primary;
  if (!fs.existsSync(file)) return { file: primary, steps: [] };
  const steps = [];
  try {
    const text = fs.readFileSync(file, "utf8");
    for (const line of text.split("\n")) {
      if (!line.trim()) continue;
      try {
        steps.push(JSON.parse(line));
      } catch {
        /* skip */
      }
    }
  } catch {
    /* */
  }
  return { file, steps };
}

function extractUserRequest(content) {
  if (typeof content !== "string") return "";
  const m = content.match(/<USER_REQUEST>\s*([\s\S]*?)\s*<\/USER_REQUEST>/i);
  if (m) return m[1].trim();
  return content
    .replace(/<ADDITIONAL_METADATA>[\s\S]*?<\/ADDITIONAL_METADATA>/gi, "")
    .replace(/<USER_SETTINGS_CHANGE>[\s\S]*?<\/USER_SETTINGS_CHANGE>/gi, "")
    .replace(/<\/?[A-Z_]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function mapAgyToolName(name) {
  const n = String(name || "").toLowerCase();
  if (n === "view_file" || n === "read_file" || n === "read_resource") return "read_file";
  if (n === "write_to_file" || n === "write_file" || n === "create_file") return "write";
  if (n === "replace_file_content" || n === "multi_replace_file_content" || n === "edit") return "search_replace";
  if (n === "run_command" || n === "bash" || n === "shell") return "run_terminal_command";
  if (n === "grep_search" || n === "search_in_file" || n === "find_by_name") return "grep";
  if (n === "list_dir" || n === "list_directory" || n === "view_folder") return "list_dir";
  if (n === "web_search" || n === "search_web") return "web_search";
  if (n === "browser_subagent" || n === "read_url_content") return "web_fetch";
  if (n === "manage_task" || n === "todo") return "todo_write";
  if (n.startsWith("mcp_") || n.includes("mcp")) return "use_tool";
  return name || "tool";
}

function mapAgyToolInput(name, args) {
  const a = args && typeof args === "object" ? args : {};
  const n = String(name || "").toLowerCase();
  if (n === "view_file" || n === "read_file") {
    return {
      target_file: a.AbsolutePath || a.absolute_path || a.path || a.FilePath || "",
      offset: a.StartLine || a.start_line || a.offset,
      limit: a.EndLine && a.StartLine ? Number(a.EndLine) - Number(a.StartLine) + 1 : a.limit,
    };
  }
  if (n === "write_to_file" || n === "write_file") {
    return {
      file_path: a.TargetFile || a.target_file || a.path || "",
      content: a.CodeContent || a.content || "",
    };
  }
  if (n === "replace_file_content" || n === "multi_replace_file_content") {
    return {
      file_path: a.TargetFile || a.target_file || a.path || "",
      old_string: a.OldString || a.old_string || "",
      new_string: a.NewString || a.new_string || "",
    };
  }
  if (n === "run_command") {
    return {
      command: a.CommandLine || a.command || a.cmd || "",
      description: a.toolSummary || a.toolAction || a.TaskDescription || "",
    };
  }
  if (n === "grep_search") {
    return {
      pattern: a.Query || a.query || a.pattern || "",
      path: a.SearchPath || a.search_path || a.path || "",
    };
  }
  if (n === "manage_task") {
    return { todos: [{ content: a.toolSummary || a.Action || "task", status: "in_progress" }] };
  }
  // Pass through but also surface common display keys.
  return {
    ...a,
    path: a.AbsolutePath || a.TargetFile || a.path || a.FilePath || "",
    command: a.CommandLine || a.command || "",
    description: a.toolSummary || a.toolAction || a.Description || "",
  };
}

function stepToolId(step, toolName, index) {
  return `agy-${step.step_index != null ? step.step_index : "x"}-${toolName || "tool"}-${index}`;
}

/**
 * Convert one transcript step into Grok-compatible synthetic NDJSON lines
 * (thought / text / tool_use / tool_result) so the server reuses Grok parsers.
 */
function stepToSyntheticLines(step, ctx) {
  const lines = [];
  if (!step || typeof step !== "object") return lines;
  const type = String(step.type || "");
  const status = String(step.status || "").toUpperCase();

  if (type === "PLANNER_RESPONSE") {
    if (typeof step.thinking === "string" && step.thinking.trim()) {
      lines.push(JSON.stringify({ type: "thought", data: step.thinking }));
    }
    if (typeof step.content === "string" && step.content.trim()) {
      lines.push(JSON.stringify({ type: "text", data: step.content }));
    }
    const calls = Array.isArray(step.tool_calls) ? step.tool_calls : [];
    calls.forEach((tc, i) => {
      if (!tc || typeof tc !== "object") return;
      const rawName = tc.name || "tool";
      const id = stepToolId(step, rawName, i);
      if (ctx && ctx.pendingTools) ctx.pendingTools.set(`${step.step_index}:${rawName}`, id);
      if (ctx && ctx.pendingByName) {
        const list = ctx.pendingByName.get(rawName) || [];
        list.push(id);
        ctx.pendingByName.set(rawName, list);
      }
      lines.push(
        JSON.stringify({
          type: "tool_use",
          id,
          name: mapAgyToolName(rawName),
          input: mapAgyToolInput(rawName, tc.args || tc.arguments || {}),
          status: "running",
        })
      );
    });
    return lines;
  }

  // Tool execution result steps (VIEW_FILE, RUN_COMMAND, …).
  const toolTypeToName = {
    VIEW_FILE: "view_file",
    RUN_COMMAND: "run_command",
    CODE_ACTION: "write_to_file",
    GREP_SEARCH: "grep_search",
    MCP_TOOL: "mcp_tool",
    GENERIC: "tool",
  };
  if (toolTypeToName[type] || type.endsWith("_TOOL") || type === "ERROR_MESSAGE") {
    let id = null;
    const mapped = toolTypeToName[type] || type.toLowerCase();
    if (ctx && ctx.pendingByName) {
      const queue = ctx.pendingByName.get(mapped) || ctx.pendingByName.get(mapAgyToolName(mapped));
      // Also try common aliases
      const candidates = [mapped, mapAgyToolName(mapped), "view_file", "run_command", "write_to_file", "grep_search"];
      for (const c of candidates) {
        const q = ctx.pendingByName.get(c);
        if (q && q.length) {
          id = q.shift();
          break;
        }
      }
    }
    if (!id) id = stepToolId(step, mapped, 0);
    const isError = type === "ERROR_MESSAGE" || status === "ERROR" || status === "FAILED";
    const content =
      (typeof step.content === "string" && step.content) ||
      (typeof step.error === "string" && step.error) ||
      "";
    if (status === "DONE" || status === "ERROR" || status === "FAILED" || type === "ERROR_MESSAGE") {
      lines.push(
        JSON.stringify({
          type: "tool_result",
          tool_use_id: id,
          content: content.slice(0, 4000),
          is_error: isError,
          status: isError ? "error" : "done",
        })
      );
    }
  }
  return lines;
}

function startAgyTranscriptTail({ cwd, sessionId, startedAtMs, onLine, onSessionId }) {
  let offset = 0;
  let partial = "";
  let stopped = false;
  let timer = null;
  let resolvedId = sessionId || null;
  let file = resolvedId ? agyTranscriptPath(resolvedId) : null;
  const seenSteps = new Set();
  const ctx = { pendingTools: new Map(), pendingByName: new Map() };
  const afterMs = startedAtMs || Date.now();

  const resolveFile = () => {
    if (!resolvedId) {
      resolvedId = findAgyConversationForCwd(cwd, afterMs);
      if (resolvedId && typeof onSessionId === "function") {
        try {
          onSessionId(resolvedId);
        } catch {
          /* */
        }
      }
    }
    if (!resolvedId) return null;
    const primary = agyTranscriptPath(resolvedId);
    const full = agyTranscriptFullPath(resolvedId);
    if (fs.existsSync(primary)) return primary;
    if (fs.existsSync(full)) return full;
    return primary; // may appear soon
  };

  const drain = () => {
    if (stopped) return;
    file = resolveFile();
    if (!file || !fs.existsSync(file)) return;
    try {
      const st = fs.statSync(file);
      if (st.size < offset) {
        offset = 0;
        partial = "";
      }
      if (st.size === offset) return;
      const fd = fs.openSync(file, "r");
      const len = st.size - offset;
      const buf = Buffer.alloc(Math.min(len, 4 * 1024 * 1024));
      const n = fs.readSync(fd, buf, 0, buf.length, offset);
      fs.closeSync(fd);
      offset += n;
      partial += buf.slice(0, n).toString("utf8");
      let idx;
      while ((idx = partial.indexOf("\n")) >= 0) {
        const line = partial.slice(0, idx);
        partial = partial.slice(idx + 1);
        if (!line.trim()) continue;
        let step = null;
        try {
          step = JSON.parse(line);
        } catch {
          continue;
        }
        // Only stream steps from THIS run. A resolved conversation file usually holds
        // PRIOR turns (agy reuses / forks conversation context, and we read from offset
        // 0), so without this guard every past PLANNER_RESPONSE.content replays and the
        // server folds them into one text node — e.g. an "ok" turn + a "hi" turn render
        // as "okhi". Steps created before the run started are history; skip them. Skew
        // tolerates minor clock/backdating differences between spawn and the CLI's writes.
        const createdMs = Date.parse(step.created_at || step.createdAt || "");
        if (Number.isFinite(createdMs) && createdMs < afterMs - AGY_TAIL_STEP_SKEW_MS) {
          continue;
        }
        const sig = `${step.step_index}:${step.type}:${step.status}:${String(step.content || "").slice(0, 40)}`;
        if (seenSteps.has(sig)) continue;
        seenSteps.add(sig);
        if (seenSteps.size > 8000) {
          const first = seenSteps.values().next().value;
          seenSteps.delete(first);
        }
        for (const syn of stepToSyntheticLines(step, ctx)) {
          try {
            onLine(syn);
          } catch {
            /* */
          }
        }
      }
    } catch {
      /* */
    }
  };

  timer = setInterval(drain, 250);
  drain();
  return {
    get sessionId() {
      return resolvedId;
    },
    get file() {
      return file;
    },
    stop() {
      if (stopped) return;
      stopped = true;
      if (timer) {
        clearInterval(timer);
        timer = null;
      }
      drain();
      // Seal turn for the server parsers.
      if (resolvedId) {
        try {
          onLine(
            JSON.stringify({
              type: "end",
              stopReason: "end_turn",
              sessionId: resolvedId,
            })
          );
        } catch {
          /* */
        }
      }
    },
  };
}

function agyWorkModeFlags(workMode) {
  const mode = String(workMode || "ask_auto").toLowerCase();
  if (mode === "full_access" || mode === "full" || mode === "danger") {
    return ["--dangerously-skip-permissions"];
  }
  if (mode === "plan" || mode === "read_only") {
    return ["--mode", "plan"];
  }
  if (mode === "allow_edits" || mode === "ask_auto" || mode === "ask") {
    return ["--mode", "accept-edits", "--dangerously-skip-permissions"];
  }
  return ["--dangerously-skip-permissions"];
}

function buildAgyArgs({ prompt, resumeId, model, workMode }) {
  const args = ["-p", String(prompt || ""), "--print-timeout", process.env.VIBE_AGY_PRINT_TIMEOUT || "30m"];
  args.push(...agyWorkModeFlags(workMode));
  if (resumeId) args.push("--conversation", String(resumeId));
  if (model) args.push("--model", String(model));
  return args;
}

module.exports = {
  AGY_DETAIL_MIDTURN_STALE_MS,
  agyHome,
  agySessionFiles,
  agyTranscriptPath,
  agyTranscriptFullPath,
  findAgyConversationForCwd,
  loadTranscriptSteps,
  extractUserRequest,
  mapAgyToolName,
  mapAgyToolInput,
  stepToSyntheticLines,
  startAgyTranscriptTail,
  buildAgyArgs,
  agyWorkModeFlags,
  isEphemeralProject,
};
