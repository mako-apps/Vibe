defmodule Vibe.AI.LocalAgentWorker do
  @moduledoc false

  require Logger

  alias Vibe.Chat
  alias Vibe.Chat.AgentMessageCrypto
  alias Vibe.Chat.GroupAgentMemory
  alias Vibe.Notifications
  alias Vibe.Repo

  # How many recent shared-thread turns to inject as collaboration context when
  # dispatching a bridge agent inside a group.
  @group_context_messages 12

  @agent_user_id Vibe.AI.GroupAgent.agent_user_id()
  # Distinct agent user identities so @claude and @codex are separate, searchable
  # users you can DM, each with their own avatar — instead of one shared bot user.
  @claude_agent_user_id "11111111-1111-1111-1111-111111111111"
  @codex_agent_user_id "22222222-2222-2222-2222-222222222222"
  @default_timeout_ms 120_000
  @max_prompt_length 8_000
  @max_tool_events 16
  @max_activity_summary_items 6
  @max_payload_preview_bytes 1_200
  @rate_limit_table :local_agent_worker_ratelimit
  @session_table :local_agent_worker_sessions
  @default_cooldown_ms 8_000

  @workers %{
    "codex" => %{
      handle: "codex",
      label: "Codex",
      command_env: "VIBE_CODEX_COMMAND",
      default_command: "codex",
      agent_user_id: @codex_agent_user_id,
      username: "codex",
      name: "Codex"
    },
    "claude" => %{
      handle: "claude",
      label: "Claude",
      command_env: "VIBE_CLAUDE_COMMAND",
      default_command: "claude",
      agent_user_id: @claude_agent_user_id,
      username: "claude",
      name: "Claude"
    }
  }

  def agent_user_id, do: @agent_user_id

  @doc "All worker definitions keyed by handle."
  def workers, do: @workers

  @doc "List of all worker definitions."
  def list_workers, do: Map.values(@workers)

  @doc "The dedicated agent user id for a worker (claude/codex are distinct users)."
  def worker_agent_user_id(%{agent_user_id: id}), do: id

  @doc "Resolve a worker by its dedicated shadow-user id (e.g. for DM auto-routing)."
  def resolve_by_agent_user_id(user_id) when is_binary(user_id) do
    normalized = user_id |> String.trim() |> String.downcase()

    Enum.find_value(@workers, fn {_handle, worker} ->
      if String.downcase(worker.agent_user_id) == normalized, do: worker
    end)
  end

  def resolve_by_agent_user_id(_), do: nil

  @doc """
  Upsert the Claude/Codex agent user records so they are searchable users you can
  DM. Idempotent — safe to call on every boot.
  """
  def ensure_agent_users do
    Enum.each(list_workers(), &ensure_agent_user_record/1)
  end

  def resolve_handle(value) when is_binary(value) do
    value
    |> normalize_handle()
    |> case do
      handle when is_map_key(@workers, handle) -> Map.fetch!(@workers, handle)
      _ -> nil
    end
  end

  def resolve_handle(_), do: nil

  def resolve_from_message(%{metadata: metadata}) when is_map(metadata) do
    metadata
    |> Map.get("agentWorkerProvider")
    |> resolve_handle()
  end

  def resolve_from_message(_), do: nil

  def extract_reserved_mention(text) when is_binary(text) do
    case Regex.run(~r/(?:^|\s)@(codex|claude)\b/i, text) do
      [_, handle] -> resolve_handle(handle)
      _ -> nil
    end
  end

  def extract_reserved_mention(_), do: nil

  def extract_reserved_mentions(text) when is_binary(text) do
    ~r/(?:^|\s)@(codex|claude)\b/i
    |> Regex.scan(text)
    |> Enum.map(fn
      [_, handle] -> resolve_handle(handle)
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.handle)
  end

  def extract_reserved_mentions(_), do: []

  def enabled? do
    truthy?(System.get_env("VIBE_LOCAL_AGENT_WORKERS"))
  end

  @doc """
  Per-user cooldown gate. Returns `true` and records the timestamp if the user
  is allowed to dispatch now, `false` if they are still within the cooldown
  window. Bounds cost and abuse from rapid `@claude` / `@codex` spamming.
  """
  def allow_request?(user_id) when is_binary(user_id) and user_id != "" do
    ensure_rate_limit_table()
    now = System.monotonic_time(:millisecond)
    cooldown = cooldown_ms()

    case :ets.lookup(@rate_limit_table, user_id) do
      [{^user_id, last}] when now - last < cooldown ->
        false

      _ ->
        :ets.insert(@rate_limit_table, {user_id, now})
        true
    end
  end

  def allow_request?(_), do: true

  @doc """
  Post a short non-result notice into the chat (rate-limited / busy messages),
  attributed to the worker agent.
  """
  def post_notice(worker, chat_id, text, requester_user_id, reply_to_id) when is_map(worker) do
    post_worker_message(
      worker,
      chat_id,
      text,
      %{
        "agentWorker" => true,
        "agentWorkerProvider" => worker.handle,
        "agentWorkerOk" => false,
        "agentWorkerNotice" => true
      },
      reply_to_id,
      requester_user_id
    )
  end

  defp ensure_rate_limit_table do
    case :ets.whereis(@rate_limit_table) do
      :undefined ->
        :ets.new(@rate_limit_table, [:set, :public, :named_table, {:read_concurrency, true}])
        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp cooldown_ms do
    case Integer.parse(System.get_env("VIBE_AGENT_WORKER_COOLDOWN_MS") || "") do
      {value, _} when value >= 0 -> value
      _ -> @default_cooldown_ms
    end
  end

  @doc """
  Authorization gate. If `VIBE_AGENT_WORKER_ALLOWED_USERS` is set (comma-separated
  user IDs), only those users may drive the local worker. If unset, all chat
  participants are allowed (backwards compatible). Set it whenever the worker runs
  with write/execute permissions so only you can trigger jobs on your machine.
  """
  def user_allowed?(user_id) do
    case allowed_users() do
      [] -> true
      list -> is_binary(user_id) and user_id in list
    end
  end

  defp allowed_users do
    case normalize_string(System.get_env("VIBE_AGENT_WORKER_ALLOWED_USERS")) do
      nil ->
        []

      raw ->
        raw
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end
  end

  defp ensure_session_table do
    case :ets.whereis(@session_table) do
      :undefined ->
        :ets.new(@session_table, [:set, :public, :named_table, {:read_concurrency, true}])
        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp lookup_session(nil, _handle), do: nil

  defp lookup_session(chat_id, handle) do
    ensure_session_table()

    case :ets.lookup(@session_table, {chat_id, handle}) do
      [{_, session_id}] -> session_id
      _ -> nil
    end
  end

  defp store_session(nil, _handle, _session_id), do: :ok
  defp store_session(_chat_id, _handle, nil), do: :ok

  defp store_session(chat_id, handle, session_id) do
    ensure_session_table()
    :ets.insert(@session_table, {{chat_id, handle}, session_id})
    :ok
  end

  defp session_id_from_output(output) do
    output
    |> decoded_events()
    |> Enum.find_value(fn event -> normalize_string(event["session_id"]) end)
  end

  def handle_chat_message(worker, chat_id, prompt, opts \\ []) when is_map(worker) do
    reply_to_id = Keyword.get(opts, :reply_to_id)
    requester_user_id = Keyword.get(opts, :requester_user_id)
    progress_callback = Keyword.get(opts, :progress_callback, fn _event -> :ok end)

    with {:ok, normalized_prompt} <- normalize_prompt(worker, prompt),
         {:ok, result} <-
           run(worker, normalized_prompt, progress_callback: progress_callback, chat_id: chat_id) do
      post_worker_message(
        worker,
        chat_id,
        visible_response_text(result.text, result.tool_events),
        %{
          "agentWorker" => true,
          "agentWorkerProvider" => worker.handle,
          "agentWorkerCommand" => result.command,
          "agentWorkerExitStatus" => result.exit_status,
          "agentWorkerDurationMs" => result.duration_ms,
          "agentWorkerOk" => result.ok,
          "agentWorkerToolEvents" => result.tool_events,
          "agentWorkerAvailableTools" => result.available_tools,
          "agentWorkerRawEventCount" => result.raw_event_count,
          "progressNodes" => result.progress_nodes
        },
        reply_to_id,
        requester_user_id
      )
    else
      {:error, reason} ->
        post_worker_message(
          worker,
          chat_id,
          error_message(worker, reason),
          %{
            "agentWorker" => true,
            "agentWorkerProvider" => worker.handle,
            "agentWorkerOk" => false,
            "agentWorkerError" => inspect(reason)
          },
          reply_to_id,
          requester_user_id
        )
    end
  end

  def run(worker, prompt, opts \\ []) when is_map(worker) and is_binary(prompt) do
    cond do
      not enabled?() ->
        {:error, :local_agent_workers_disabled}

      String.length(prompt) > @max_prompt_length ->
        {:error, :prompt_too_long}

      true ->
        command = command_for(worker)

        case System.find_executable(command) do
          nil ->
            {:error, {:command_not_found, command}}

          executable ->
            do_run(worker, executable, prompt, opts)
        end
    end
  end

  def parse_result(provider, output) when is_binary(provider) and is_binary(output) do
    case resolve_handle(provider) do
      nil -> {:error, :unknown_provider}
      worker -> {:ok, extract_result(worker, output)}
    end
  end

  # ── Bridge entrypoints ──────────────────────────────────────────────
  # The bridge daemon runs claude/codex on the user's own computer and ships the
  # RAW stream-json output back. The server reuses the full parsing pipeline below
  # so the daemon stays thin and we have one source of truth for parsing.

  @doc """
  Turn a single raw stream-json line from a bridge daemon into a progress event
  (or nil if the line carries no tool activity). Used to stream live progress
  into the chat while the task runs on the user's machine.
  """
  def bridge_progress_event(provider, line) when is_binary(line) do
    case resolve_handle(provider) do
      nil -> nil
      worker -> progress_event_from_line(line, worker)
    end
  end

  def bridge_progress_event(_provider, _line), do: nil

  @doc """
  Parse a completed bridge run (raw output + exit status) and post the result as
  the agent's message into the chat. Mirrors `handle_chat_message/4`'s success and
  failure formatting, but for output produced on the user's computer.
  """
  def deliver_bridge_result(provider, chat_id, output, exit_status, duration_ms, opts \\ [])
      when is_binary(provider) and is_binary(chat_id) and is_binary(output) do
    case resolve_handle(provider) do
      nil ->
        {:error, :unknown_provider}

      worker ->
        reply_to_id = Keyword.get(opts, :reply_to_id)
        requester_user_id = Keyword.get(opts, :requester_user_id)
        extracted = extract_result(worker, output)
        ok = exit_status == 0
        base_text = extracted.text || fallback_output(output)

        body =
          if ok do
            visible_response_text(base_text, extracted.tool_events)
          else
            visible_response_text(
              command_failed_text(worker, exit_status, base_text),
              extracted.tool_events
            )
          end

        # Add the agent's answer to the shared group thread so the other agent can
        # build on it next turn. Only on success — don't pollute memory with errors.
        if ok, do: note_bridge_agent_turn(chat_id, worker, base_text, requester_user_id)

        Logger.info(
          "[AgentBridge] deliver chat=#{chat_id} provider=#{worker.handle} ok=#{ok} rawEvents=#{extracted.raw_event_count} baseTextLen=#{String.length(base_text || "")} bodyLen=#{String.length(body || "")}"
        )

        result =
          post_worker_message(
            worker,
            chat_id,
            body,
            %{
              "agentWorker" => true,
              "agentWorkerProvider" => worker.handle,
              "agentWorkerVia" => "bridge",
              "agentWorkerExitStatus" => exit_status,
              "agentWorkerDurationMs" => duration_ms,
              "agentWorkerOk" => ok,
              "agentWorkerToolEvents" => extracted.tool_events,
              "agentWorkerAvailableTools" => extracted.available_tools,
              "agentWorkerRawEventCount" => extracted.raw_event_count,
              "progressNodes" => extracted.progress_nodes
            },
            reply_to_id,
            requester_user_id
          )

        case result do
          {:ok, %{message_id: mid}} ->
            Logger.info("[AgentBridge] deliver posted chat=#{chat_id} message_id=#{mid}")

          other ->
            Logger.error(
              "[AgentBridge] deliver FAILED chat=#{chat_id} provider=#{worker.handle} reason=#{inspect(other)}"
            )
        end

        result
    end
  end

  @doc "Post a short notice (e.g. errors from the bridge) attributed to a worker."
  def post_bridge_notice(provider, chat_id, text, requester_user_id, reply_to_id) do
    case resolve_handle(provider) do
      nil -> {:error, :unknown_provider}
      worker -> post_notice(worker, chat_id, text, requester_user_id, reply_to_id)
    end
  end

  # ── Shared group memory (Claude + Codex collaborating) ──────────────
  # Vibe is E2E encrypted, so the server can't read humans' stored messages. But
  # it CAN see every agent prompt (sent in cleartext as `agentText`) and every
  # agent reply (generated server-side). That stream IS the agents' shared
  # collaboration thread: we persist it in `GroupAgentMemory` (keyed by chat) and
  # re-inject it as context so @claude and @codex can build on each other's work.
  # In a 1:1 DM the agent keeps its own `--resume` continuity, so we skip all of
  # this and send the raw prompt unchanged.

  @doc """
  Build the prompt to send to the bridge. In a group, prepend a speaker-labelled
  collaboration context (recent turns + any summary) plus a short framing so the
  agent knows it shares the conversation with the other agents and people. In a
  DM, returns `dispatch_text` unchanged.
  """
  def build_bridge_prompt(chat_id, worker, dispatch_text, requester_user_id)
      when is_binary(chat_id) and is_map(worker) and is_binary(dispatch_text) do
    if group_chat?(chat_id) do
      context = group_collaboration_context(chat_id, requester_user_id)

      if context == "" do
        dispatch_text
      else
        """
        #{group_framing(worker)}

        Shared conversation so far (you can see everyone's recent messages and the other agents' work — build on it, don't repeat what's already done):
        #{context}

        Latest request for you (#{worker.label}):
        #{dispatch_text}
        """
        |> String.trim()
      end
    else
      dispatch_text
    end
  end

  def build_bridge_prompt(_chat_id, _worker, dispatch_text, _requester), do: dispatch_text

  @doc "Record a human's prompt to a worker into the shared group memory (no-op in DMs)."
  def note_bridge_user_turn(chat_id, worker, text, requester_user_id)
      when is_binary(chat_id) and is_map(worker) do
    if group_chat?(chat_id) do
      GroupAgentMemory.append_message(
        chat_id,
        %{
          "role" => "user",
          "content" => clean_for_memory(text),
          "user_id" => requester_user_id,
          "sender_name" => sender_display_name(requester_user_id),
          "target_agent" => worker.handle
        },
        acting_user_id: requester_user_id
      )
    end

    :ok
  end

  def note_bridge_user_turn(_chat_id, _worker, _text, _requester), do: :ok

  @doc "Record a worker's answer into the shared group memory (no-op in DMs)."
  def note_bridge_agent_turn(chat_id, worker, text, requester_user_id)
      when is_binary(chat_id) and is_map(worker) do
    if is_binary(text) and String.trim(text) != "" and group_chat?(chat_id) do
      GroupAgentMemory.append_message(
        chat_id,
        %{
          "role" => "assistant",
          "content" => clean_for_memory(text),
          "agent" => worker.handle,
          "agent_name" => worker.label
        },
        acting_user_id: requester_user_id
      )
    end

    :ok
  end

  def note_bridge_agent_turn(_chat_id, _worker, _text, _requester), do: :ok

  defp group_chat?(chat_id) do
    case Chat.get_room_type(chat_id) do
      "dm" -> false
      nil -> false
      _ -> true
    end
  end

  defp group_framing(worker) do
    "You are #{worker.label}, collaborating with other AI agents (#{other_agents_label(worker)}) " <>
      "and people in a shared Vibe group chat. Everyone shares this conversation. When you finish, " <>
      "your reply is posted back into the group so the others can continue from it."
  end

  defp other_agents_label(worker) do
    list_workers()
    |> Enum.reject(&(&1.handle == worker.handle))
    |> Enum.map_join(", ", & &1.label)
    |> case do
      "" -> "other agents"
      names -> names
    end
  end

  defp group_collaboration_context(chat_id, requester_user_id) do
    case GroupAgentMemory.get_or_create(chat_id, acting_user_id: requester_user_id) do
      {:ok, memory} ->
        summary_part =
          case memory.summary do
            s when is_binary(s) and s != "" -> "Summary of earlier discussion: #{s}\n"
            _ -> ""
          end

        lines =
          memory.messages
          |> List.wrap()
          |> Enum.take(-@group_context_messages)
          |> Enum.map(&format_thread_line/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.join("\n")

        (summary_part <> lines) |> String.trim()

      _ ->
        ""
    end
  end

  defp format_thread_line(%{"role" => "assistant"} = msg) do
    name = msg["agent_name"] || "Agent"

    case truncate_line(msg["content"]) do
      "" -> nil
      content -> "#{name}: #{content}"
    end
  end

  defp format_thread_line(%{"role" => "user"} = msg) do
    who = msg["sender_name"] || "A teammate"

    label =
      case msg["target_agent"] do
        target when is_binary(target) and target != "" -> "#{who} → #{String.capitalize(target)}"
        _ -> who
      end

    case truncate_line(msg["content"]) do
      "" -> nil
      content -> "#{label}: #{content}"
    end
  end

  defp format_thread_line(_), do: nil

  defp truncate_line(nil), do: ""

  defp truncate_line(text) when is_binary(text) do
    collapsed = text |> String.replace(~r/\s+/u, " ") |> String.trim()

    if String.length(collapsed) > 500,
      do: String.slice(collapsed, 0, 497) <> "...",
      else: collapsed
  end

  defp truncate_line(_), do: ""

  # Strip reserved @mentions before storing/re-injecting so the daemon's mention
  # scrubber never mangles our context labels, and labels stay clean.
  defp clean_for_memory(text) when is_binary(text) do
    text
    |> String.replace(~r/(^|\s)@(claude|codex)\b/iu, "\\1")
    |> String.trim()
  end

  defp clean_for_memory(_), do: ""

  defp sender_display_name(user_id) when is_binary(user_id) do
    case Vibe.Accounts.get_user(user_id) do
      %{name: name} when is_binary(name) and name != "" -> name
      _ -> "A teammate"
    end
  rescue
    _ -> "A teammate"
  end

  defp sender_display_name(_), do: "A teammate"

  # ── Activity broadcast helpers (shared by chat + bridge channels) ────

  @doc "Broadcast a typing/agent-progress event into a chat for an agent."
  def broadcast_activity(chat_id, agent_user_id, label, status, tool \\ nil) do
    VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "typing", %{
      "userId" => agent_user_id,
      "isAgent" => true
    })

    payload =
      %{"userId" => agent_user_id, "isAgent" => true, "label" => label, "status" => status}
      |> then(fn payload ->
        case tool do
          value when is_binary(value) and value != "" -> Map.put(payload, "tool", value)
          _ -> payload
        end
      end)

    VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "agent-progress", payload)
  end

  @doc """
  Parse the bridge output accumulated so far and broadcast a live `agent-stream`
  update (partial text + inline progress/tool nodes) into the chat, so the reply
  appears as it is produced instead of arriving as one final batch. Reuses the
  same `extract_result/2` parser as the final delivery — one source of truth.
  """
  def bridge_stream_update(provider, chat_id, accumulated_output, stream_id)
      when is_binary(provider) and is_binary(chat_id) and is_binary(accumulated_output) do
    case resolve_handle(provider) do
      nil ->
        :ok

      worker ->
        extracted = extract_result(worker, accumulated_output)
        text = normalize_string(extracted.text) || ""

        VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "agent-stream", %{
          "chatId" => chat_id,
          "streamId" => stream_id,
          "userId" => worker.agent_user_id,
          "isAgent" => true,
          "text" => text,
          "progressNodes" => extracted.progress_nodes,
          "toolEvents" => extracted.tool_events,
          "status" => "running"
        })

        :ok
    end
  end

  def bridge_stream_update(_provider, _chat_id, _output, _stream_id), do: :ok

  @doc "Mark a live stream finished. The final persisted message carries the content."
  def finish_stream(provider, chat_id, stream_id) do
    agent_id =
      case resolve_handle(provider) do
        nil -> agent_user_id()
        worker -> worker.agent_user_id
      end

    VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "agent-stream", %{
      "chatId" => chat_id,
      "streamId" => stream_id,
      "userId" => agent_id,
      "isAgent" => true,
      "status" => "done"
    })
  end

  @doc "Broadcast that an agent has finished working in a chat."
  def stop_activity(chat_id, agent_user_id) do
    VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "agent-progress", %{
      "userId" => agent_user_id,
      "isAgent" => true,
      "status" => "done"
    })

    VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "stop-typing", %{
      "userId" => agent_user_id,
      "isAgent" => true
    })
  end

  defp do_run(%{handle: "codex"} = worker, executable, prompt, opts) do
    sandbox =
      System.get_env("VIBE_CODEX_SANDBOX")
      |> normalize_string()
      |> case do
        value when value in ["read-only", "workspace-write", "danger-full-access"] -> value
        _ -> "read-only"
      end

    args =
      [
        "exec",
        "--json",
        "--sandbox",
        sandbox,
        "--cd",
        worker_cwd(),
        "--skip-git-repo-check",
        "--ephemeral"
      ] ++ maybe_model_args("VIBE_CODEX_MODEL", "--model") ++ [prompt]

    run_command(worker, executable, args, opts)
  end

  defp do_run(%{handle: "claude"} = worker, executable, prompt, opts) do
    permission_mode =
      System.get_env("VIBE_CLAUDE_PERMISSION_MODE")
      |> normalize_string()
      |> case do
        value when value in ["default", "acceptEdits", "bypassPermissions", "plan"] ->
          value

        _ ->
          "plan"
      end

    output_format =
      System.get_env("VIBE_CLAUDE_OUTPUT_FORMAT")
      |> normalize_string()
      |> case do
        value when value in ["json", "stream-json", "text"] -> value
        _ -> "stream-json"
      end

    args =
      [
        "-p",
        "--output-format",
        output_format,
        "--permission-mode",
        permission_mode
      ] ++
        claude_session_args(worker, Keyword.get(opts, :chat_id)) ++
        maybe_claude_verbose_args(output_format) ++
        maybe_model_args("VIBE_CLAUDE_MODEL", "--model") ++
        maybe_single_arg("VIBE_CLAUDE_MCP_CONFIG", "--mcp-config") ++
        maybe_single_arg("VIBE_CLAUDE_ALLOWED_TOOLS", "--allowedTools") ++
        maybe_single_arg("VIBE_CLAUDE_DISALLOWED_TOOLS", "--disallowedTools") ++ ["--", prompt]

    run_command(worker, executable, args, opts)
  end

  # Per-chat conversation continuity: resume the same Claude session for a chat so
  # follow-up @claude messages keep context. One-off runs (no chat_id) stay stateless.
  defp claude_session_args(worker, chat_id) do
    case lookup_session(chat_id, worker.handle) do
      session_id when is_binary(session_id) -> ["--resume", session_id]
      _ when is_binary(chat_id) -> []
      _ -> ["--no-session-persistence"]
    end
  end

  defp run_command(worker, executable, args, opts) do
    start = System.monotonic_time(:millisecond)
    timeout_ms = timeout_ms()
    progress_callback = Keyword.get(opts, :progress_callback, fn _event -> :ok end)

    Logger.info(
      "[LocalAgentWorker] start provider=#{worker.handle} command=#{Path.basename(executable)} timeout_ms=#{timeout_ms}"
    )

    line_callback = fn line ->
      line
      |> progress_event_from_line(worker)
      |> case do
        nil -> :ok
        event -> progress_callback.(event)
      end
    end

    case collect_command(executable, args, worker_cwd(), timeout_ms, line_callback) do
      {:ok, status, output} ->
        duration_ms = System.monotonic_time(:millisecond) - start
        extracted = extract_result(worker, output)
        text = extracted.text || fallback_output(output)
        ok = status == 0

        if ok do
          store_session(
            Keyword.get(opts, :chat_id),
            worker.handle,
            session_id_from_output(output)
          )
        end

        Logger.info(
          "[LocalAgentWorker] finish provider=#{worker.handle} status=#{status} duration_ms=#{duration_ms} text_len=#{String.length(text)}"
        )

        {:ok,
         %{
           ok: ok,
           exit_status: status,
           command: Path.basename(executable),
           duration_ms: duration_ms,
           text: if(ok, do: text, else: command_failed_text(worker, status, text)),
           tool_events: extracted.tool_events,
           available_tools: extracted.available_tools,
           raw_event_count: extracted.raw_event_count,
           progress_nodes: extracted.progress_nodes
         }}

      {:error, :timeout, output} ->
        {:error, {:timeout, timeout_ms, fallback_output(output)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_command(executable, args, cwd, timeout_ms, line_callback) do
    shell = System.find_executable("sh") || "/bin/sh"
    shell_command = "exec </dev/null\nexec " <> shell_join([executable | args])

    port =
      Port.open({:spawn_executable, shell}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, ["-lc", shell_command]},
        {:cd, cwd}
      ])

    collect_port(port, [], "", line_callback, System.monotonic_time(:millisecond) + timeout_ms)
  rescue
    error -> {:error, error}
  end

  defp collect_port(port, chunks, line_buffer, line_callback, deadline_ms) do
    remaining = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        {lines, next_line_buffer} = split_complete_lines(line_buffer <> data)
        Enum.each(lines, &safe_line_callback(line_callback, &1))
        collect_port(port, [data | chunks], next_line_buffer, line_callback, deadline_ms)

      {^port, {:exit_status, status}} ->
        if normalize_string(line_buffer), do: safe_line_callback(line_callback, line_buffer)
        {:ok, status, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
    after
      remaining ->
        Port.close(port)
        {:error, :timeout, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
    end
  end

  defp post_worker_message(worker, chat_id, body, metadata, reply_to_id, requester_user_id) do
    agent_user_id = worker.agent_user_id

    with :ok <- ensure_agent_user_record(worker) do
      message_id = Ecto.UUID.generate()
      timestamp = System.system_time(:millisecond)
      plain_text = normalize_string(body) || ""

      metadata =
        metadata
        |> Map.put("isAgentMessage", true)
        |> Map.put("agentName", worker.label)
        |> Map.put("agentUserId", agent_user_id)
        |> Map.put("agentUsername", worker.handle)
        |> Map.put("agentHandle", "@#{worker.handle}")

      attrs = %{
        id: message_id,
        chat_id: chat_id,
        from_id: agent_user_id,
        encrypted_content: AgentMessageCrypto.encrypt_for_storage(plain_text),
        type: "text",
        metadata: metadata,
        reply_to_id: reply_to_id,
        timestamp: timestamp
      }

      case Chat.add_message(attrs, acting_user_id: requester_user_id || @agent_user_id) do
        {:ok, _message} ->
          payload = %{
            "id" => message_id,
            "fromId" => agent_user_id,
            "chatId" => chat_id,
            "encryptedContent" => "",
            "plainContent" => plain_text,
            "plaintext" => plain_text,
            "type" => "text",
            "timestamp" => timestamp,
            "status" => "sent",
            "isAgentMessage" => true,
            "agentName" => worker.label,
            "agentUserId" => agent_user_id,
            "agentUsername" => worker.handle,
            "agentHandle" => "@#{worker.handle}",
            "metadata" => metadata,
            "replyToId" => reply_to_id
          }

          VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "message", payload)
          notify_chat_participants(chat_id, agent_user_id, message_id, timestamp, plain_text)
          {:ok, %{message_id: message_id, timestamp: timestamp}}

        error ->
          error
      end
    end
  end

  defp notify_chat_participants(chat_id, agent_user_id, message_id, timestamp, body) do
    Chat.get_all_participant_settings(chat_id)
    |> Enum.each(fn participant ->
      if participant.user_id != agent_user_id do
        if participant.deleted, do: Chat.restore_if_deleted(chat_id, participant.user_id)

        VibeWeb.Endpoint.broadcast!("user:#{participant.user_id}", "new_message", %{
          chat_id: chat_id,
          from_id: agent_user_id,
          message_id: message_id,
          timestamp: timestamp,
          muted: participant.muted || false
        })

        if not participant.muted do
          _ =
            Notifications.send_message_push(participant.user_id, %{
              "chat_id" => chat_id,
              "message_id" => message_id,
              "from_id" => agent_user_id,
              "type" => "text",
              "body" => body
            })
        end
      end
    end)
  end

  defp ensure_agent_user_record(worker) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    agent_user_id = Ecto.UUID.dump!(worker.agent_user_id)

    Repo.insert_all(
      "users",
      [
        %{
          id: agent_user_id,
          username: worker.username,
          name: worker.name,
          password_hash: "agent",
          public_key: "agent",
          device_id: "agent",
          is_agent: true,
          inserted_at: now,
          updated_at: now
        }
      ],
      conflict_target: [:id],
      on_conflict: [set: [updated_at: now, name: worker.name, is_agent: true]]
    )

    :ok
  rescue
    error -> {:error, error}
  end

  defp normalize_prompt(_worker, prompt) do
    cleaned =
      prompt
      |> to_string()
      |> String.replace(~r/(?:^|\s)@(codex|claude)\b/i, " ")
      |> String.trim()

    cond do
      cleaned == "" -> {:error, :missing_prompt}
      String.length(cleaned) > @max_prompt_length -> {:error, :prompt_too_long}
      true -> {:ok, cleaned}
    end
  end

  defp command_for(worker) do
    System.get_env(worker.command_env)
    |> normalize_string()
    |> Kernel.||(worker.default_command)
  end

  defp worker_cwd do
    case normalize_string(System.get_env("VIBE_AGENT_WORKER_CWD")) do
      nil -> default_workspace_dir()
      path -> path
    end
  end

  # Secure default: run the agent in an isolated scratch directory, NOT the live
  # server repo. Set VIBE_AGENT_WORKER_CWD explicitly to grant access elsewhere.
  defp default_workspace_dir do
    dir = Path.join(System.tmp_dir!() || "/tmp", "vibe-agent-workspace")
    File.mkdir_p(dir)
    dir
  end

  defp timeout_ms do
    case Integer.parse(System.get_env("VIBE_AGENT_WORKER_TIMEOUT_MS") || "") do
      {value, _} when value >= 5_000 and value <= 900_000 -> value
      _ -> @default_timeout_ms
    end
  end

  defp maybe_model_args(env_name, flag) do
    case normalize_string(System.get_env(env_name)) do
      nil -> []
      model -> [flag, model]
    end
  end

  defp maybe_single_arg(env_name, flag) do
    case normalize_string(System.get_env(env_name)) do
      nil -> []
      value -> [flag, value]
    end
  end

  defp maybe_claude_verbose_args("stream-json"), do: ["--verbose"]
  defp maybe_claude_verbose_args(_), do: []

  defp extract_result(worker, output) do
    decoded = decoded_events(output)
    tool_events = tool_events_from_decoded(worker, decoded)

    %{
      text: extract_worker_text(worker, decoded, output),
      tool_events: tool_events,
      available_tools: available_tools_from_decoded(worker, decoded),
      raw_event_count: length(decoded),
      progress_nodes: progress_nodes_from_events(tool_events)
    }
  end

  defp extract_worker_text(%{handle: "codex"}, decoded, output) do
    extract_codex_text(decoded) || plain_output_text(decoded, output)
  end

  defp extract_worker_text(%{handle: "claude"}, decoded, output) do
    extract_claude_text(decoded) || plain_output_text(decoded, output)
  end

  defp extract_worker_text(_worker, decoded, output), do: plain_output_text(decoded, output)

  defp plain_output_text([], output), do: normalize_string(output)
  defp plain_output_text(_decoded, _output), do: nil

  defp decoded_events(output) do
    line_events =
      output
      |> to_string()
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        case Jason.decode(line) do
          {:ok, event} when is_map(event) -> [event]
          {:ok, events} when is_list(events) -> Enum.filter(events, &is_map/1)
          _ -> []
        end
      end)

    if line_events != [] do
      line_events
    else
      case Jason.decode(output) do
        {:ok, event} when is_map(event) -> [event]
        {:ok, events} when is_list(events) -> Enum.filter(events, &is_map/1)
        _ -> []
      end
    end
  end

  defp extract_codex_text(decoded) do
    decoded
    |> Enum.reduce(nil, fn event, acc ->
      item = map_value(event, "item") || event

      cond do
        codex_agent_message?(item) and is_binary(item["text"]) ->
          item["text"]

        is_binary(event["message"]) ->
          event["message"]

        true ->
          acc
      end
    end)
    |> normalize_string()
  end

  defp extract_claude_text(decoded) do
    result_text =
      decoded
      |> Enum.reduce(nil, fn event, acc ->
        cond do
          is_binary(event["result"]) ->
            event["result"]

          is_binary(event["content"]) ->
            event["content"]

          is_map(event["message"]) ->
            content_blocks_text(event["message"]["content"]) || acc

          true ->
            acc
        end
      end)
      |> normalize_string()

    result_text ||
      decoded
      |> Enum.flat_map(fn event ->
        event
        |> content_blocks_from_event()
        |> Enum.filter(&match?(%{"type" => "text"}, &1))
        |> Enum.map(&(&1["text"] || ""))
      end)
      |> Enum.join("\n")
      |> normalize_string()
  end

  defp tool_events_from_decoded(%{handle: "claude"}, decoded) do
    decoded
    |> claude_tool_events()
    |> Enum.take(@max_tool_events)
  end

  defp tool_events_from_decoded(%{handle: "codex"}, decoded) do
    decoded
    |> codex_tool_events()
    |> Enum.take(@max_tool_events)
  end

  defp tool_events_from_decoded(_worker, _decoded), do: []

  defp claude_tool_events(decoded) do
    {events_by_id, order} =
      Enum.reduce(decoded, {%{}, []}, fn event, acc ->
        event
        |> content_blocks_from_event()
        |> Enum.reduce(acc, &accumulate_claude_tool_block/2)
      end)

    order
    |> Enum.uniq()
    |> Enum.map(&Map.fetch!(events_by_id, &1))
  end

  defp accumulate_claude_tool_block(%{"type" => "tool_use"} = block, {events_by_id, order}) do
    id = normalize_string(block["id"]) || unique_event_id("claude-tool", length(order))
    tool = normalize_string(block["name"]) || "tool"
    input = block["input"] || %{}

    event =
      %{
        "id" => id,
        "provider" => "claude",
        "tool" => tool,
        "label" => tool_label("Claude", tool, input),
        "status" => "running",
        "input" => safe_payload(input),
        "providerEventType" => "tool_use"
      }
      |> put_node_shape(tool, input)

    {Map.put(events_by_id, id, event), append_once(order, id)}
  end

  defp accumulate_claude_tool_block(%{"type" => "tool_result"} = block, {events_by_id, order}) do
    id =
      normalize_string(block["tool_use_id"]) ||
        normalize_string(block["id"]) ||
        unique_event_id("claude-result", length(order))

    existing = Map.get(events_by_id, id)
    tool = (existing && existing["tool"]) || "tool_result"
    output = block["content"] || block["text"] || block["result"]
    status = if block["is_error"] == true, do: "failed", else: "done"

    event =
      (existing ||
         %{
           "id" => id,
           "provider" => "claude",
           "tool" => tool,
           "label" => tool_label("Claude", tool, %{}),
           "input" => %{}
         })
      |> Map.merge(%{
        "status" => status,
        "outputPreview" => safe_text(output),
        "providerEventType" => "tool_result"
      })

    {Map.put(events_by_id, id, event), append_once(order, id)}
  end

  defp accumulate_claude_tool_block(_block, acc), do: acc

  defp codex_tool_events(decoded) do
    decoded
    |> Enum.with_index()
    |> Enum.flat_map(fn {event, index} ->
      item = map_value(event, "item") || event
      item_type = normalize_string(item["type"]) || normalize_string(event["type"]) || ""

      cond do
        codex_agent_message?(item) ->
          []

        codex_toolish_event?(event, item, item_type) ->
          [codex_tool_event(event, item, item_type, index)]

        true ->
          []
      end
    end)
    |> compact_tool_events()
  end

  defp codex_tool_event(event, item, item_type, index) do
    tool = codex_tool_name(item, item_type)
    input = codex_tool_input(item)

    %{
      "id" =>
        normalize_string(item["id"]) ||
          normalize_string(event["id"]) ||
          unique_event_id("codex-tool", index),
      "provider" => "codex",
      "tool" => tool,
      "label" => tool_label("Codex", tool, input),
      "status" => codex_event_status(event, item),
      "input" => safe_payload(input),
      "outputPreview" => safe_text(codex_tool_output(item)),
      "providerEventType" => normalize_string(event["type"]) || item_type
    }
    |> put_node_shape(tool, input)
  end

  defp codex_toolish_event?(event, item, item_type) do
    event_type = normalize_string(event["type"]) || ""

    cond do
      item_type in ["agent_message", "message", "reasoning"] ->
        false

      is_binary(item["command"]) or is_list(item["command"]) ->
        true

      is_binary(item["name"]) or is_binary(item["tool"]) or is_binary(item["tool_name"]) ->
        true

      String.contains?(item_type, ["tool", "command", "exec", "function", "call", "search"]) ->
        true

      String.contains?(event_type, ["tool", "command", "exec", "function", "call"]) and
          not String.contains?(event_type, "agent_message") ->
        true

      true ->
        false
    end
  end

  defp codex_agent_message?(%{"type" => "agent_message"}), do: true
  defp codex_agent_message?(_), do: false

  defp codex_tool_name(item, item_type) do
    cond do
      is_binary(item["command"]) or is_list(item["command"]) ->
        "Bash"

      normalize_string(item["name"]) ->
        normalize_string(item["name"])

      normalize_string(item["tool"]) ->
        normalize_string(item["tool"])

      normalize_string(item["tool_name"]) ->
        normalize_string(item["tool_name"])

      item_type != "" ->
        item_type
        |> String.replace("_", " ")
        |> String.split(" ", trim: true)
        |> Enum.map_join(" ", &String.capitalize/1)

      true ->
        "Tool"
    end
  end

  defp codex_tool_input(item) do
    cond do
      is_map(item["input"]) ->
        item["input"]

      is_map(item["arguments"]) ->
        item["arguments"]

      is_binary(item["arguments"]) ->
        %{"arguments" => item["arguments"]}

      is_binary(item["command"]) ->
        %{"command" => item["command"]}

      is_list(item["command"]) ->
        %{"command" => Enum.join(item["command"], " ")}

      true ->
        %{}
    end
  end

  defp codex_tool_output(item) do
    item["output"] || item["result"] || item["content"] || item["text"]
  end

  defp codex_event_status(event, item) do
    status =
      [
        event["type"],
        event["status"],
        item["status"]
      ]
      |> Enum.find_value(&normalize_string/1)
      |> Kernel.||("")
      |> String.downcase()

    cond do
      String.contains?(status, ["fail", "error"]) -> "failed"
      String.contains?(status, ["complete", "completed", "done", "success"]) -> "done"
      String.contains?(status, ["start", "running", "progress"]) -> "running"
      true -> "running"
    end
  end

  defp compact_tool_events(events) do
    {events_by_id, order} =
      Enum.reduce(events, {%{}, []}, fn event, {events_by_id, order} ->
        id = event["id"]

        {Map.merge(Map.get(events_by_id, id, %{}), event)
         |> then(&Map.put(events_by_id, id, &1)), append_once(order, id)}
      end)

    order
    |> Enum.uniq()
    |> Enum.map(&Map.fetch!(events_by_id, &1))
  end

  defp available_tools_from_decoded(%{handle: "claude"}, decoded) do
    decoded
    |> Enum.flat_map(fn
      %{"tools" => tools} when is_list(tools) -> tools
      %{"message" => %{"tools" => tools}} when is_list(tools) -> tools
      _ -> []
    end)
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.take(40)
  end

  defp available_tools_from_decoded(_worker, _decoded), do: []

  defp progress_nodes_from_events(events) do
    events
    |> Enum.with_index()
    |> Enum.map(fn {event, index} ->
      %{
        "id" => event["id"] || unique_event_id("worker-progress", index),
        "label" => event["label"] || event["tool"] || "Working...",
        "status" => event["status"] || "running",
        "depth" => 0
      }
      |> copy_node_shape(event)
    end)
  end

  # ── Claude-Code-style node shape (kind / target / patch stats) ──────
  # Enrich a tool event with the structured fields the app renders as a live
  # read/edit/patch feed inside the chat bubble. Computed from the RAW tool
  # input (before truncation) so patch line counts are accurate.
  defp put_node_shape(event, tool, input) do
    {kind, target} = tool_kind_and_target(tool, input)

    event =
      event
      |> Map.put("kind", kind)
      |> maybe_put("target", target)

    case patch_stats(tool, input) do
      {added, removed} when added > 0 or removed > 0 ->
        event |> Map.put("added", added) |> Map.put("removed", removed)

      _ ->
        event
    end
  end

  # Copy the structured shape fields from a tool event onto a progress node.
  defp copy_node_shape(node, event) do
    ["kind", "target", "added", "removed"]
    |> Enum.reduce(node, fn key, acc ->
      case Map.get(event, key) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Map a provider tool name + input to a coarse kind and a short target
  # (file basename, command, pattern, url…) for compact display.
  defp tool_kind_and_target(tool, input) when is_map(input) do
    t = tool |> to_string() |> String.downcase()
    path = input["file_path"] || input["filePath"] || input["path"] || input["notebook_path"]

    cond do
      t in ["read", "notebookread", "view", "cat", "open"] ->
        {"read", target_basename(path)}

      t in ["edit", "multiedit", "notebookedit", "str_replace", "str_replace_editor", "update", "apply_patch", "applypatch"] ->
        {"edit", target_basename(path)}

      t in ["write", "create", "createfile", "new_file"] ->
        {"write", target_basename(path)}

      t in ["bash", "shell", "exec", "run", "command", "terminal"] ->
        {"bash", short_target(input["command"] || input["cmd"])}

      t in ["grep", "search", "glob", "find", "ripgrep", "rg"] ->
        {"search", short_target(input["pattern"] || input["query"] || path)}

      t in ["webfetch", "websearch", "fetch", "web_search", "web_fetch", "browse"] ->
        {"web", short_target(input["url"] || input["query"] || input["domain"])}

      t in ["task", "agent", "dispatch_agent"] ->
        {"task", short_target(input["description"] || input["prompt"])}

      t in ["todowrite", "todo"] ->
        {"todo", nil}

      true ->
        {"tool", target_basename(path) || short_target(input["command"])}
    end
  end

  defp tool_kind_and_target(tool, _input), do: {to_string(tool) |> String.downcase(), nil}

  defp target_basename(path) when is_binary(path) do
    case Path.basename(String.trim(path)) do
      "" -> nil
      base -> base
    end
  end

  defp target_basename(_), do: nil

  defp short_target(value) do
    value
    |> safe_text()
    |> normalize_string()
    |> case do
      nil -> nil
      text -> text |> String.replace(~r/\s+/, " ") |> truncate(80)
    end
  end

  # Approximate added/removed line counts for file-mutating tools, mirroring
  # Claude Code's +N/−M. nil for non-mutating tools.
  defp patch_stats(tool, input) when is_map(input) do
    t = tool |> to_string() |> String.downcase()

    cond do
      t in ["write", "create", "createfile", "new_file"] ->
        {line_count(input["content"] || input["file_text"] || input["text"]), 0}

      t in ["edit", "notebookedit", "str_replace", "str_replace_editor", "update"] ->
        {line_count(input["new_string"] || input["newString"] || input["new_str"] || input["new_source"]),
         line_count(input["old_string"] || input["oldString"] || input["old_str"] || input["old_source"])}

      t in ["multiedit"] ->
        (input["edits"] || [])
        |> Enum.reduce({0, 0}, fn edit, {add, del} ->
          {add + line_count(edit["new_string"] || edit["newString"]),
           del + line_count(edit["old_string"] || edit["oldString"])}
        end)

      true ->
        nil
    end
  end

  defp patch_stats(_tool, _input), do: nil

  defp line_count(value) when is_binary(value) do
    case String.trim_trailing(value, "\n") do
      "" -> 0
      trimmed -> trimmed |> String.split("\n") |> length()
    end
  end

  defp line_count(_), do: 0

  defp progress_event_from_line(line, worker) do
    with {:ok, event} when is_map(event) <- Jason.decode(line),
         tool_event when is_map(tool_event) <-
           Enum.find(tool_events_from_decoded(worker, [event]), fn event ->
             event["providerEventType"] != "tool_result"
           end) do
      Map.put(tool_event, "status", "running")
    else
      _ -> nil
    end
  end

  defp content_blocks_from_event(%{"message" => %{"content" => content}}),
    do: content_blocks_from_value(content)

  defp content_blocks_from_event(%{"content" => content}), do: content_blocks_from_value(content)
  defp content_blocks_from_event(_), do: []

  defp content_blocks_from_value(content) when is_list(content),
    do: Enum.filter(content, &is_map/1)

  defp content_blocks_from_value(content) when is_map(content), do: [content]
  defp content_blocks_from_value(_), do: []

  defp content_blocks_text(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      %{"text" => text} when is_binary(text) -> text
      _ -> ""
    end)
    |> Enum.join("\n")
    |> normalize_string()
  end

  defp content_blocks_text(_), do: nil

  defp visible_response_text(text, events) do
    text = normalize_string(text) || "The command finished without returning text."

    case activity_summary(events) do
      nil -> text
      summary -> text <> "\n\nActivity\n" <> summary
    end
  end

  defp activity_summary([]), do: nil

  defp activity_summary(events) do
    events
    |> Enum.take(@max_activity_summary_items)
    |> Enum.map(fn event ->
      label = event["label"] || event["tool"] || "Tool"
      status = event["status"] || "running"
      "- #{label} (#{status})"
    end)
    |> Enum.join("\n")
    |> then(fn summary ->
      extra = length(events) - @max_activity_summary_items
      if extra > 0, do: summary <> "\n- #{extra} more tool event(s)", else: summary
    end)
    |> normalize_string()
  end

  defp tool_label(provider, tool, input) do
    case tool_detail(input) do
      nil -> "#{provider} #{tool}"
      detail -> "#{provider} #{tool}: #{truncate(detail, 96)}"
    end
  end

  defp tool_detail(input) when is_map(input) do
    [
      "command",
      "cmd",
      "description",
      "path",
      "file_path",
      "filePath",
      "pattern",
      "query",
      "url",
      "prompt"
    ]
    |> Enum.find_value(fn key ->
      input
      |> Map.get(key)
      |> safe_text()
      |> normalize_string()
    end)
  end

  defp tool_detail(input), do: input |> safe_text() |> normalize_string()

  defp safe_payload(value) when is_map(value) do
    value
    |> Enum.take(12)
    |> Map.new(fn {key, value} ->
      key = to_string(key)

      if secret_key?(key) do
        {key, "[redacted]"}
      else
        {key, safe_payload(value)}
      end
    end)
  end

  defp safe_payload(value) when is_list(value) do
    value
    |> Enum.take(12)
    |> Enum.map(&safe_payload/1)
  end

  defp safe_payload(value) when is_binary(value), do: truncate(value, @max_payload_preview_bytes)
  defp safe_payload(value) when is_number(value) or is_boolean(value) or is_nil(value), do: value
  defp safe_payload(value), do: value |> inspect() |> truncate(@max_payload_preview_bytes)

  defp safe_text(nil), do: nil

  defp safe_text(value) when is_binary(value), do: truncate(value, @max_payload_preview_bytes)

  defp safe_text(value) when is_list(value) do
    value
    |> Enum.map(fn
      %{"text" => text} when is_binary(text) -> text
      %{"content" => content} -> safe_text(content)
      item when is_binary(item) -> item
      item -> inspect(item)
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> truncate(@max_payload_preview_bytes)
  end

  defp safe_text(value) when is_map(value),
    do: value |> safe_payload() |> inspect() |> truncate(@max_payload_preview_bytes)

  defp safe_text(value), do: value |> inspect() |> truncate(@max_payload_preview_bytes)

  defp secret_key?(key) do
    key
    |> String.downcase()
    |> then(
      &String.contains?(&1, ["secret", "token", "password", "api_key", "apikey", "private_key"])
    )
  end

  defp append_once(values, value) do
    if value in values, do: values, else: values ++ [value]
  end

  defp unique_event_id(prefix, index), do: "#{prefix}-#{index}"

  defp map_value(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_map(value) -> value
      _ -> nil
    end
  end

  defp split_complete_lines(data) do
    parts = String.split(data, "\n", trim: false)

    case Enum.reverse(parts) do
      [tail | reversed_complete] -> {Enum.reverse(reversed_complete), tail}
      [] -> {[], ""}
    end
  end

  defp safe_line_callback(callback, line) do
    callback.(String.trim_trailing(line, "\r"))
  rescue
    error ->
      Logger.debug("[LocalAgentWorker] progress callback failed: #{inspect(error)}")
      :ok
  end

  defp shell_join(args) do
    Enum.map_join(args, " ", &shell_quote/1)
  end

  defp shell_quote(arg) do
    value = to_string(arg)

    if Regex.match?(~r/^[A-Za-z0-9_\/:.,=@%+\-]+$/, value) do
      value
    else
      "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
    end
  end

  defp fallback_output(output) do
    output
    |> to_string()
    |> String.trim()
    |> truncate(6_000)
    |> case do
      "" -> "The command finished without returning text."
      text -> text
    end
  end

  defp command_failed_text(worker, status, text) do
    """
    #{worker.label} command exited with status #{status}.

    #{truncate(text, 5_500)}
    """
    |> String.trim()
  end

  defp error_message(worker, :local_agent_workers_disabled) do
    "#{worker.label} local worker is disabled. Set `VIBE_LOCAL_AGENT_WORKERS=1` on the server that runs Vibe to allow @#{worker.handle} tasks."
  end

  defp error_message(worker, {:command_not_found, command}) do
    "#{worker.label} command `#{command}` was not found on this server."
  end

  defp error_message(worker, {:timeout, timeout_ms, output}) do
    "#{worker.label} timed out after #{div(timeout_ms, 1000)}s.\n\n#{truncate(output, 4_000)}"
  end

  defp error_message(worker, :missing_prompt), do: "Tell @#{worker.handle} what task to run."

  defp error_message(worker, reason) do
    "#{worker.label} could not run this task: #{inspect(reason)}"
  end

  defp normalize_handle(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.trim_leading("@")
    |> String.downcase()
  end

  defp normalize_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_string(_), do: nil

  defp truthy?(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()
    normalized in ["1", "true", "yes", "on", "enabled"]
  end

  defp truthy?(_), do: false

  defp truncate(text, limit) when is_binary(text) and byte_size(text) > limit do
    String.slice(text, 0, limit) <> "\n...[truncated]"
  end

  defp truncate(text, _limit), do: text
end
