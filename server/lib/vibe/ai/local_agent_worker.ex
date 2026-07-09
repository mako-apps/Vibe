defmodule Vibe.AI.LocalAgentWorker do
  @moduledoc false

  require Logger

  alias Vibe.AgentBridge
  alias Vibe.Badges
  alias Vibe.Chat
  alias Vibe.Chat.AgentMessageCrypto
  alias Vibe.Chat.GroupAgentMemory
  alias Vibe.Notifications
  alias Vibe.Repo

  # How many recent shared-thread turns to inject as collaboration context when
  # dispatching a bridge agent inside a group.
  @group_context_messages 12

  @agent_user_id Vibe.AI.GroupAgent.agent_user_id()
  # Distinct agent user identities so @claude / @codex / @grok / @agy are separate,
  # searchable users you can DM, each with their own avatar — instead of one
  # shared bot user.
  @claude_agent_user_id "11111111-1111-1111-1111-111111111111"
  @codex_agent_user_id "22222222-2222-2222-2222-222222222222"
  @grok_agent_user_id "33333333-3333-3333-3333-333333333333"
  @agy_agent_user_id "44444444-4444-4444-4444-444444444444"
  @claude_avatar_data_url "https://media.vibegram.io/chat-media/agent-profiles/claude.png"
  @codex_avatar_data_url "https://media.vibegram.io/chat-media/agent-profiles/codex.png"
  @grok_avatar_data_url "https://media.vibegram.io/chat-media/agent-profiles/grok-v2.png"
  @agy_avatar_data_url "https://media.vibegram.io/chat-media/agent-profiles/agy.png"
  @default_timeout_ms 120_000
  @max_prompt_length 8_000
  @max_tool_events 16
  @max_activity_summary_items 6
  @max_payload_preview_bytes 1_200
  @max_runtime_files 32
  @max_runtime_patch_bytes 90_000
  @rate_limit_table :local_agent_worker_ratelimit
  @session_table :local_agent_worker_sessions
  @team_run_table :local_agent_worker_team_runs
  @default_cooldown_ms 8_000
  @worker_order ["claude", "codex", "grok", "agy"]

  @workers %{
    "codex" => %{
      handle: "codex",
      label: "Codex",
      command_env: "VIBE_CODEX_COMMAND",
      default_command: "codex",
      agent_user_id: @codex_agent_user_id,
      username: "codex",
      name: "Codex",
      avatar_url: @codex_avatar_data_url,
      tier: "gold"
    },
    "claude" => %{
      handle: "claude",
      label: "Claude",
      command_env: "VIBE_CLAUDE_COMMAND",
      default_command: "claude",
      agent_user_id: @claude_agent_user_id,
      username: "claude",
      name: "Claude",
      avatar_url: @claude_avatar_data_url,
      tier: "gold"
    },
    "grok" => %{
      handle: "grok",
      label: "Grok",
      command_env: "VIBE_GROK_COMMAND",
      default_command: "grok",
      agent_user_id: @grok_agent_user_id,
      username: "grok",
      name: "Grok",
      avatar_url: @grok_avatar_data_url,
      tier: "gold"
    },
    "agy" => %{
      handle: "agy",
      label: "Agy",
      command_env: "VIBE_AGY_COMMAND",
      default_command: "agy",
      agent_user_id: @agy_agent_user_id,
      username: "agy",
      name: "Agy",
      avatar_url: @agy_avatar_data_url,
      tier: "gold"
    }
  }

  def agent_user_id, do: @agent_user_id

  @doc "All worker definitions keyed by handle."
  def workers, do: @workers

  @doc "List of all worker definitions."
  def list_workers do
    @worker_order
    |> Enum.map(&Map.fetch!(@workers, &1))
  end

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
    case Regex.run(~r/(?:^|\s)@(codex|claude|grok|agy|antigravity)\b/i, text) do
      [_, handle] ->
        h = String.downcase(handle)
        resolve_handle(if(h == "antigravity", do: "agy", else: h))

      _ ->
        nil
    end
  end

  def extract_reserved_mention(_), do: nil

  def extract_reserved_mentions(text) when is_binary(text) do
    ~r/(?:^|\s)@(codex|claude|grok|agy|antigravity)\b/i
    |> Regex.scan(text)
    |> Enum.map(fn
      [_, handle] ->
        h = String.downcase(handle)
        resolve_handle(if(h == "antigravity", do: "agy", else: h))

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.handle)
  end

  def extract_reserved_mentions(_), do: []

  @doc """
  Whether a message is a short greeting / acknowledgement / chit-chat with no
  actionable task. Used to skip the "read AGENTS.md / inspect the repo" operating
  rules so a plain "hi" doesn't make the agents start crawling the codebase before
  the user has actually asked for any work.
  """
  def casual_message?(text) when is_binary(text) do
    normalized = text |> String.downcase() |> String.trim()

    cond do
      normalized == "" ->
        true

      String.length(normalized) <= 40 and
          Regex.match?(
            ~r/^(hi+|hey+|hello+|yo|gm|gn|good (morning|afternoon|evening|night)|sup|what'?s up|howdy|hiya|hola|greetings|thanks|thank you|ty|thx|cheers|ok|okay|k|cool|nice|great|awesome|got it|gotcha|lol+|haha+|hehe|👋|🙏|👍|🙂|😄)[\s!.,?👋🙏👍🙂😄]*$/u,
            normalized
          ) ->
        true

      true ->
        false
    end
  end

  def casual_message?(_), do: false

  @doc "Whether a message is explicitly asking the local AI workers to run as a team."
  def team_trigger?(text) when is_binary(text) do
    Regex.match?(~r/(?:^|\s)(?:@team|\/team)\b/i, text) or
      Regex.match?(~r/^\s*team\s*:/i, text)
  end

  def team_trigger?(_), do: false

  @doc "Remove the team command token before sending the actual user task to providers."
  def strip_team_trigger(text) when is_binary(text) do
    text
    |> String.replace(~r/(^|\s)(?:@team|\/team)\b/i, "\\1")
    |> String.replace(~r/^\s*team\s*:\s*/i, "")
    |> String.trim()
    |> case do
      "" -> String.trim(text)
      cleaned -> cleaned
    end
  end

  def strip_team_trigger(text), do: text

  @doc """
  Return local workers whose shadow users are participants in the group.
  This keeps each user's group isolated: the bridge dispatch still uses the
  requester user id, while the participant list only decides which local agents
  are allowed to respond in that group.
  """
  def team_workers_for_participants(participant_ids) when is_list(participant_ids) do
    normalized_ids =
      participant_ids
      |> Enum.map(&(to_string(&1) |> String.downcase() |> String.trim()))
      |> MapSet.new()

    list_workers()
    |> Enum.filter(fn worker ->
      MapSet.member?(normalized_ids, String.downcase(worker.agent_user_id))
    end)
  end

  def team_workers_for_participants(_), do: []

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
        runtime = normalize_runtime_payload(Keyword.get(opts, :runtime))
        # End-to-end encrypted runtime blob. Opaque to the server: stored and
        # served verbatim, never decrypted, parsed, or logged. The key lives
        # only on the user's bridge and phone.
        runtime_enc = normalize_runtime_enc(Keyword.get(opts, :runtime_enc))
        agent_actions_enc = normalize_runtime_enc(Keyword.get(opts, :agent_actions_enc))
        runtime_can_revert = Keyword.get(opts, :can_revert) == true
        team_metadata = normalize_team_metadata(opts)
        extracted = extract_result(worker, output)
        progress_nodes = progress_nodes_with_runtime(extracted.progress_nodes, runtime)
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

        metadata =
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
            "progressNodes" => progress_nodes
          }
          |> maybe_put("agentRuntime", runtime)
          |> maybe_put("agentRuntimeEnc", runtime_enc)
          |> maybe_put("agentActionsEnc", agent_actions_enc)
          |> maybe_put("agentRuntimeCanRevert", if(runtime_can_revert, do: true))
          |> Map.merge(team_metadata)

        result =
          post_worker_message(
            worker,
            chat_id,
            body,
            metadata,
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

        maybe_dispatch_next_team_worker(chat_id, worker, requester_user_id, opts)

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

      if casual_message?(dispatch_text) do
        # Greeting / chit-chat: no operating rules, no "read AGENTS.md". Vanilla
        # claude/codex don't touch the repo unprompted — it was our injected rules
        # that made a plain "hi" kick off file reads. Keep it conversational.
        """
        #{group_framing(worker)}

        The latest message is casual conversation, not a work request. Reply briefly and in a friendly, human way. Do NOT read repo files (AGENTS.md, CLAUDE.md, etc.), inspect the codebase, or run any tools — only start doing real work once the user actually asks for it.

        Shared conversation so far:
        #{context_or_empty(context)}

        Latest message for you (#{worker.label}):
        #{dispatch_text}
        """
        |> String.trim()
      else
        """
        #{group_framing(worker)}

        #{agent_operating_rules(worker)}

        Shared conversation so far (you can see everyone's recent messages and the other agents' work; build on it and do not repeat completed work):
        #{context_or_empty(context)}

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

  @doc """
  Build a team-run prompt for a worker. The server remains the coordinator and
  the selected repo remains on the user's bridge machine; the prompt gives both
  agents a stable team run id plus an optional shared repo handoff file.
  """
  def build_team_bridge_prompt(
        chat_id,
        worker,
        dispatch_text,
        requester_user_id,
        team_workers,
        team_run_id
      )
      when is_binary(chat_id) and is_map(worker) and is_binary(dispatch_text) do
    if group_chat?(chat_id) do
      context = group_collaboration_context(chat_id, requester_user_id)
      teammate_names = team_workers_label(team_workers)
      teammate_handles = team_workers_handles(team_workers)
      handoff_path = ".vibe/team/#{safe_team_run_id(team_run_id)}.md"

      """
      You are #{worker.label} in a Vibe team run.

      Team run id: #{team_run_id || "unknown"}
      Teammates in this run: #{teammate_names}
      Team handles: #{teammate_handles}

      Collaboration rules:
      #{agent_operating_rules(worker, handoff_path)}

      Shared Vibe group memory:
      #{context_or_empty(context)}

      Latest team request:
      #{dispatch_text}
      """
      |> String.trim()
    else
      dispatch_text
    end
  end

  def build_team_bridge_prompt(_chat_id, _worker, dispatch_text, _requester, _workers, _run_id),
    do: dispatch_text

  @doc "Start an in-memory bridge team run and return the first worker to dispatch."
  def register_bridge_team_run(
        chat_id,
        team_run_id,
        workers,
        dispatch_text,
        requester_user_id,
        reply_to_id,
        bridge_metadata
      )
      when is_binary(chat_id) and is_binary(team_run_id) and is_list(workers) do
    handles = Enum.map(workers, & &1.handle)

    case handles do
      [] ->
        nil

      [first | remaining] ->
        ensure_team_run_table()

        :ets.insert(
          @team_run_table,
          {{chat_id, team_run_id},
           %{
             chat_id: chat_id,
             team_run_id: team_run_id,
             workers: handles,
             remaining: remaining,
             dispatch_text: dispatch_text,
             requester_user_id: requester_user_id,
             reply_to_id: reply_to_id,
             bridge_metadata: bridge_metadata || %{},
             started_at: System.system_time(:millisecond)
           }}
        )

        resolve_handle(first)
    end
  end

  def register_bridge_team_run(_, _, _, _, _, _, _), do: nil

  @doc "Remove stale or completed team sequencing state."
  def clear_bridge_team_run(chat_id, team_run_id) do
    ensure_team_run_table()
    :ets.delete(@team_run_table, {chat_id, team_run_id})
    :ok
  end

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

  @doc "Record a human team request once, instead of once per dispatched worker."
  def note_bridge_team_user_turn(chat_id, workers, text, requester_user_id, team_run_id)
      when is_binary(chat_id) and is_list(workers) do
    if group_chat?(chat_id) do
      GroupAgentMemory.append_message(
        chat_id,
        %{
          "role" => "user",
          "content" => clean_for_memory(strip_team_trigger(text)),
          "user_id" => requester_user_id,
          "sender_name" => sender_display_name(requester_user_id),
          "target_agent" => "team",
          "target_agents" => Enum.map(workers, & &1.handle),
          "team_run_id" => team_run_id
        },
        acting_user_id: requester_user_id
      )
    end

    :ok
  end

  def note_bridge_team_user_turn(_chat_id, _workers, _text, _requester, _team_run_id), do: :ok

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

  defp maybe_dispatch_next_team_worker(chat_id, worker, requester_user_id, opts) do
    team_run_id = normalize_string(Keyword.get(opts, :team_run_id))

    cond do
      is_nil(team_run_id) ->
        :ok

      is_nil(requester_user_id) ->
        clear_bridge_team_run(chat_id, team_run_id)

      true ->
        dispatch_next_team_worker(chat_id, team_run_id, worker, requester_user_id)
    end
  end

  defp dispatch_next_team_worker(chat_id, team_run_id, completed_worker, requester_user_id) do
    ensure_team_run_table()

    case :ets.lookup(@team_run_table, {chat_id, team_run_id}) do
      [{{^chat_id, ^team_run_id}, state}] ->
        remaining = Map.get(state, :remaining, [])

        case remaining do
          [] ->
            clear_bridge_team_run(chat_id, team_run_id)

          [next_handle | rest] ->
            :ets.insert(@team_run_table, {{chat_id, team_run_id}, %{state | remaining: rest}})

            dispatch_team_worker_from_state(
              state,
              next_handle,
              completed_worker,
              requester_user_id
            )
        end

      _ ->
        :ok
    end
  end

  defp dispatch_team_worker_from_state(state, next_handle, completed_worker, requester_user_id) do
    case resolve_handle(next_handle) do
      nil ->
        clear_bridge_team_run(state.chat_id, state.team_run_id)

      next_worker ->
        team_workers =
          state.workers
          |> Enum.map(&resolve_handle/1)
          |> Enum.reject(&is_nil/1)

        bridge_prompt =
          build_team_bridge_prompt(
            state.chat_id,
            next_worker,
            state.dispatch_text,
            requester_user_id,
            team_workers,
            state.team_run_id
          )

        broadcast_activity(
          state.chat_id,
          next_worker.agent_user_id,
          "#{next_worker.label} continuing team run after #{completed_worker.label}...",
          "running"
        )

        task_payload =
          %{
            "provider" => next_worker.handle,
            "chatId" => state.chat_id,
            "taskId" => "#{state.team_run_id}-#{next_worker.handle}",
            "prompt" => bridge_prompt,
            "replyToId" => state.reply_to_id,
            "requesterUserId" => requester_user_id,
            "teamMode" => "group_team",
            "teamRunId" => state.team_run_id,
            "teamWorker" => next_worker.handle,
            "teamWorkers" => Enum.map(team_workers, & &1.handle)
          }
          |> Map.merge(resolve_provider_model(state.bridge_metadata || %{}, next_worker.handle))

        case AgentBridge.dispatch_task(requester_user_id, task_payload) do
          :ok ->
            Logger.info(
              "[LocalAgentWorker] chained team dispatch chat=#{state.chat_id} run=#{state.team_run_id} from=#{completed_worker.handle} to=#{next_worker.handle}"
            )

          {:error, :offline} ->
            stop_activity(state.chat_id, next_worker.agent_user_id)

            post_notice(
              next_worker,
              state.chat_id,
              "Your computer went offline before @#{next_worker.handle} could continue the team run.",
              requester_user_id,
              state.reply_to_id
            )

            clear_bridge_team_run(state.chat_id, state.team_run_id)
        end
    end
  end

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

  defp agent_operating_rules(worker, handoff_path \\ nil) do
    provider_file =
      case worker.handle do
        "claude" -> "CLAUDE.md"
        "codex" -> "CODEX.md"
        "grok" -> "AGENTS.md"
        "agy" -> "AGENTS.md"
        _ -> nil
      end

    provider_line =
      if provider_file do
        "- If the selected repo has #{provider_file} or .vibe/instructions/#{provider_file}, read it after AGENTS.md and follow it."
      end

    handoff_line =
      if is_binary(handoff_path) and handoff_path != "" do
        "- When repo writes are allowed, use #{handoff_path} as the shared handoff file. Keep edits additive under a \"#{worker.label}\" section: ownership, findings, files changed, blockers, and next steps."
      else
        "- If working with another agent, read teammate notes before continuing and avoid duplicate work."
      end

    [
      "Operating rules:",
      "- Act like a senior engineer in a production codebase.",
      "- Inspect existing code before editing and follow local patterns.",
      "- Keep changes scoped to the user's request; do not do unrelated refactors.",
      "- If the selected repo has AGENTS.md or .vibe/instructions/AGENTS.md, read it before editing and follow it.",
      provider_line,
      "- Start with read-only inspection when risk is unclear.",
      "- Do not delete files, reset git state, force push, rotate secrets, or run destructive commands unless the user explicitly approves.",
      "- Surface commands, files touched, patches, blockers, verification, and remaining risk clearly for Vibe's mobile UI.",
      "- If a command needs approval, explain the exact command, why it is needed, and the risk.",
      "- If the user assigns work by name, follow that assignment exactly.",
      "- If work is not assigned, choose a non-overlapping slice that fits your strengths and say what you took.",
      handoff_line,
      "- If a teammate is offline, unavailable, or rate-limited, say that clearly and continue with useful work that will not conflict.",
      "- Final replies should include what you completed, what was tested, what remains, and any handoff needed by the other teammate."
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
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
      cond do
        msg["target_agent"] == "team" ->
          "#{who} -> Team"

        is_binary(msg["target_agent"]) and msg["target_agent"] != "" ->
          "#{who} -> #{String.capitalize(msg["target_agent"])}"

        true ->
          who
      end

    label =
      case msg["team_run_id"] do
        run_id when is_binary(run_id) and run_id != "" -> "#{label} (team #{run_id})"
        _ -> label
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
    |> String.replace(~r/(^|\s)@(claude|codex|grok|agy|antigravity|team)\b/iu, "\\1")
    |> String.replace(~r/(^|\s)\/team\b/iu, "\\1")
    |> String.replace(~r/^\s*team\s*:\s*/iu, "")
    |> String.trim()
  end

  defp clean_for_memory(_), do: ""

  defp team_workers_label(workers) do
    workers
    |> List.wrap()
    |> Enum.map(& &1.label)
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> case do
      [] -> "Claude, Codex, Grok"
      names -> Enum.join(names, ", ")
    end
  end

  defp team_workers_handles(workers) do
    workers
    |> List.wrap()
    |> Enum.map(&"@#{&1.handle}")
    |> Enum.reject(&(&1 == "@"))
    |> case do
      [] -> "@claude, @codex, @grok, @agy"
      handles -> Enum.join(handles, ", ")
    end
  end

  defp context_or_empty(""), do: "No previous shared group memory yet."
  defp context_or_empty(nil), do: "No previous shared group memory yet."
  defp context_or_empty(context), do: context

  defp safe_team_run_id(nil), do: "current"

  defp safe_team_run_id(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_.-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "current"
      safe -> String.slice(safe, 0, 80)
    end
  end

  defp sender_display_name(user_id) when is_binary(user_id) do
    case Vibe.Accounts.get_user(user_id) do
      %{name: name} when is_binary(name) and name != "" -> name
      _ -> "A teammate"
    end
  rescue
    _ -> "A teammate"
  end

  defp sender_display_name(_), do: "A teammate"

  defp ensure_team_run_table do
    case :ets.whereis(@team_run_table) do
      :undefined ->
        :ets.new(@team_run_table, [:set, :public, :named_table, {:read_concurrency, true}])
        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

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
  def bridge_stream_update(provider, chat_id, accumulated_output, stream_id) do
    bridge_stream_update(provider, chat_id, accumulated_output, stream_id, %{})
  end

  def bridge_stream_update(provider, chat_id, accumulated_output, stream_id, metadata)
      when is_binary(provider) and is_binary(chat_id) and is_binary(accumulated_output) do
    case resolve_handle(provider) do
      nil ->
        :ok

      worker ->
        extracted = extract_result(worker, accumulated_output)
        text = normalize_string(extracted.text) || ""
        # The CLI's init/system event (Claude) or thread.started (Codex) carries the
        # session id and lands within the first few output lines, so it's available on
        # nearly every tick. Threading it to the phone lets a reconnect re-arm the same
        # live-tail path History uses (agent-bridge-history detail request) instead of
        # only recovering turns the user happened to open History on.
        session_id = session_id_from_output(accumulated_output)

        payload =
          %{
            "chatId" => chat_id,
            "streamId" => stream_id,
            "userId" => worker.agent_user_id,
            "isAgent" => true,
            "text" => text,
            # Live feed = ONE interleaved chronological flow (narration text ↔ Read/
            # Edit/Run steps), exactly like the finished "Worked" card — NOT a tool-only
            # band detached from a separate streaming-text block. The live agent view
            # renders this feed as the single source of truth and suppresses the separate
            # answer body, so the in-progress answer tail must ride here too (hence
            # live_progress_nodes, which keeps the tail the finished path drops).
            "progressNodes" =>
              live_progress_nodes(worker, extracted)
              |> mark_latest_progress_node_running(),
            "toolEvents" => extracted.tool_events,
            "status" => "running"
          }
          |> maybe_put("taskId", metadata["taskId"] || metadata[:task_id])
          |> maybe_put("sessionId", session_id)
          |> maybe_put(
            "sourceMessageId",
            metadata["sourceMessageId"] || metadata[:source_message_id]
          )
          |> maybe_put("replyToId", metadata["replyToId"] || metadata[:reply_to_id])
          |> maybe_put("repoName", metadata["repoName"] || metadata[:repo_name])
          |> maybe_put("cwd", metadata["cwd"] || metadata[:cwd])
          |> maybe_put("workMode", metadata["workMode"] || metadata[:work_mode])
          |> maybe_put("model", metadata["model"] || metadata[:model])
          |> maybe_put("advisor", metadata["advisor"] || metadata[:advisor])
          |> maybe_put(
            "bridgeSentAtMs",
            metadata["bridgeSentAtMs"] || metadata["bridge_sent_at_ms"] ||
              metadata[:bridge_sent_at_ms]
          )
          |> maybe_put(
            "serverReceivedAtMs",
            metadata["serverReceivedAtMs"] || metadata["server_received_at_ms"] ||
              metadata[:server_received_at_ms]
          )
          |> maybe_put("serverBroadcastAtMs", System.system_time(:millisecond))
          |> maybe_put("sequence", metadata["sequence"] || metadata[:sequence])
          |> maybe_put("teamMode", metadata["teamMode"] || metadata[:team_mode])
          |> maybe_put("teamRunId", metadata["teamRunId"] || metadata[:team_run_id])
          |> maybe_put("teamWorker", metadata["teamWorker"] || metadata[:team_worker])
          |> maybe_put(
            "teamWorkers",
            normalize_team_workers(metadata["teamWorkers"] || metadata[:team_workers])
          )

        VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "agent-stream", payload)

        :ok
    end
  end

  def bridge_stream_update(_provider, _chat_id, _output, _stream_id, _metadata), do: :ok

  defp mark_latest_progress_node_running(nodes) when is_list(nodes) do
    {marked, _done} =
      nodes
      |> Enum.reverse()
      |> Enum.map_reduce(false, fn node, done ->
        cond do
          done ->
            {node, done}

          node["status"] in ["failed", "error", "cancelled", "canceled", "stopped"] ->
            {node, done}

          true ->
            {Map.put(node, "status", "running"), true}
        end
      end)

    Enum.reverse(marked)
  end

  defp mark_latest_progress_node_running(nodes), do: nodes

  # Progress nodes for the LIVE stream feed. Same interleaved shape as the finished
  # "Worked" card (text ↔ tools, chronological) but WITH the in-progress answer tail:
  # build_progress_nodes drops the block equal to the summary (it re-renders as the
  # message body once finished), but during the run the live agent view suppresses the
  # body and shows this feed alone — so passing an empty summary keeps the tail visible.
  defp live_progress_nodes(%{handle: "claude"}, extracted) do
    interleaved_claude_progress_nodes(extracted.decoded, extracted.tool_events, "")
    |> with_live_thinking(extracted.decoded)
  end

  defp live_progress_nodes(%{handle: "codex"}, extracted) do
    interleaved_codex_progress_nodes(extracted.decoded, extracted.tool_events, "")
  end

  defp live_progress_nodes(%{handle: "grok"}, extracted) do
    interleaved_grok_progress_nodes(extracted.decoded, extracted.tool_events, "")
    |> with_live_thinking(extracted.decoded)
  end

  # Agy reuses the Grok NDJSON contract (bridge synthesizes thought/text/tool_use).
  defp live_progress_nodes(%{handle: "agy"}, extracted) do
    interleaved_grok_progress_nodes(extracted.decoded, extracted.tool_events, "")
    |> with_live_thinking(extracted.decoded)
    |> rewrite_progress_node_provider_prefix("grok", "agy")
  end

  defp live_progress_nodes(_worker, extracted), do: extracted.progress_nodes

  # Real-time thinking token counter. `claude --include-partial-messages` streams the
  # reasoning as `thinking_delta` events (the persisted JSONL only ever gets the block
  # once complete, so history can't tick). Forwarding every delta would flood the
  # server's whole-buffer reparse, so the bridge coalesces them into a throttled
  # `{"type":"vibe_thinking","tokens":N,"active":bool}` line. Here we fold the LAST such
  # signal onto the turn's Thinking node so the DM shows "Thinking · N tokens" ticking
  # live, exactly like the desktop CLI. Only on the live path — the finished/history
  # render gets its settled token count + duration from the bridge history transcript.
  defp with_live_thinking(nodes, decoded) do
    case last_vibe_thinking(decoded) do
      nil ->
        nodes

      {tokens, active} ->
        status = if active, do: "streaming", else: "done"

        case last_thinking_index(nodes) do
          nil ->
            # No completed-message thinking block yet (thinking is still streaming) —
            # append a live node so the counter shows before the block finalizes.
            nodes ++
              [
                %{
                  "id" => "claude-thinking-live",
                  "label" => "Thinking",
                  "status" => status,
                  "kind" => "thinking",
                  "depth" => 0,
                  "tokens" => tokens
                }
              ]

          idx ->
            node =
              nodes
              |> Enum.at(idx)
              |> Map.put("tokens", tokens)
              |> Map.put("status", status)

            List.replace_at(nodes, idx, node)
        end
    end
  end

  defp last_vibe_thinking(decoded) do
    Enum.reduce(decoded, nil, fn ev, acc ->
      if is_map(ev) and ev["type"] == "vibe_thinking" do
        {normalize_runtime_int(ev["tokens"]) || 0, ev["active"] == true}
      else
        acc
      end
    end)
  end

  defp last_thinking_index(nodes) do
    nodes
    |> Enum.with_index()
    |> Enum.reduce(nil, fn {node, idx}, acc ->
      if is_map(node) and node["kind"] == "thinking", do: idx, else: acc
    end)
  end

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

  # Collapse per-provider "models"/"advisors" maps (group fan-out metadata) onto
  # this worker's single options and drop the maps so they never reach the bridge. Mirrors
  # VibeWeb.ChatChannel.resolve_provider_model/2 for the chained team dispatch path.
  defp resolve_provider_model(bridge_metadata, provider) do
    {models, rest} = Map.pop(bridge_metadata, "models")
    {advisors, rest} = Map.pop(rest, "advisors")
    provider_key = String.downcase(to_string(provider))

    rest =
      case is_map(models) && models[provider_key] do
        model when is_binary(model) and model != "" -> Map.put(rest, "model", model)
        _ -> rest
      end

    case is_map(advisors) && advisors[provider_key] do
      advisor when is_binary(advisor) and advisor != "" -> Map.put(rest, "advisor", advisor)
      _ -> rest
    end
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
    bridge_options = Keyword.get(opts, :bridge_metadata) || %{}

    sandbox =
      System.get_env("VIBE_CODEX_SANDBOX")
      |> normalize_string()
      |> case do
        value when value in ["read-only", "workspace-write", "danger-full-access"] -> value
        _ -> "read-only"
      end

    approval_policy =
      System.get_env("VIBE_CODEX_APPROVAL_POLICY")
      |> normalize_string()
      |> case do
        value when value in ["untrusted", "on-request", "never"] -> value
        _ -> "untrusted"
      end

    args =
      [
        "exec",
        "--json",
        "--sandbox",
        sandbox,
        "-c",
        "approval_policy=\"#{approval_policy}\"",
        "--cd",
        worker_cwd(),
        "--skip-git-repo-check",
        "--ephemeral"
      ] ++
        maybe_model_args(bridge_options, "VIBE_CODEX_MODEL", "--model") ++
        codex_reasoning_args(bridge_options) ++ [prompt]

    run_command(worker, executable, args, opts)
  end

  defp do_run(%{handle: "claude"} = worker, executable, prompt, opts) do
    bridge_options = Keyword.get(opts, :bridge_metadata) || %{}

    permission_mode =
      System.get_env("VIBE_CLAUDE_PERMISSION_MODE")
      |> normalize_string()
      |> case do
        value
        when value in ["default", "acceptEdits", "auto", "dontAsk", "bypassPermissions", "plan"] ->
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
        claude_effort_args(bridge_options) ++
        claude_session_args(bridge_options) ++
        maybe_claude_verbose_args(output_format) ++
        maybe_model_args(bridge_options, "VIBE_CLAUDE_MODEL", "--model") ++
        maybe_advisor_args(bridge_options) ++
        maybe_single_arg("VIBE_CLAUDE_MCP_CONFIG", "--mcp-config") ++
        maybe_single_arg("VIBE_CLAUDE_ALLOWED_TOOLS", "--allowedTools") ++
        maybe_single_arg("VIBE_CLAUDE_DISALLOWED_TOOLS", "--disallowedTools") ++ ["--", prompt]

    run_command(worker, executable, args, opts)
  end

  # Antigravity CLI (`agy -p`): plain final text on stdout; bridge injects full
  # payload from transcript.jsonl as Grok-shaped NDJSON.
  defp do_run(%{handle: "agy"} = worker, executable, prompt, opts) do
    bridge_options = Keyword.get(opts, :bridge_metadata) || %{}

    args =
      ["-p", prompt, "--print-timeout", System.get_env("VIBE_AGY_PRINT_TIMEOUT") || "30m"] ++
        agy_mode_args(bridge_options) ++
        agy_session_args(bridge_options) ++
        maybe_model_args(bridge_options, "VIBE_AGY_MODEL", "--model")

    run_command(worker, executable, args, opts)
  end

  defp agy_session_args(bridge_options) do
    case explicit_resume_session_id(bridge_options) do
      session_id when is_binary(session_id) -> ["--conversation", session_id]
      _ -> []
    end
  end

  defp agy_mode_args(bridge_options) do
    mode =
      bridge_options
      |> option_value("workMode")
      |> normalize_string()
      |> case do
        value when value in ["plan", "read_only"] -> "plan"
        value when value in ["full_access", "full", "danger"] -> "full"
        _ -> "accept"
      end

    case mode do
      "plan" -> ["--mode", "plan"]
      "full" -> ["--dangerously-skip-permissions"]
      _ -> ["--mode", "accept-edits", "--dangerously-skip-permissions"]
    end
  end

  # Grok Build TUI headless: `grok -p <prompt> --output-format streaming-json`
  # emits NDJSON thought/text/end lines (see docs/agent-payload-shapes.md).
  defp do_run(%{handle: "grok"} = worker, executable, prompt, opts) do
    bridge_options = Keyword.get(opts, :bridge_metadata) || %{}

    permission_mode =
      System.get_env("VIBE_GROK_PERMISSION_MODE")
      |> normalize_string()
      |> case do
        value
        when value in ["default", "acceptEdits", "auto", "dontAsk", "bypassPermissions", "plan"] ->
          value

        _ ->
          "default"
      end

    output_format =
      System.get_env("VIBE_GROK_OUTPUT_FORMAT")
      |> normalize_string()
      |> case do
        value when value in ["json", "streaming-json", "plain"] -> value
        _ -> "streaming-json"
      end

    args =
      [
        "-p",
        prompt,
        "--output-format",
        output_format,
        "--permission-mode",
        permission_mode
      ] ++
        grok_effort_args(bridge_options) ++
        grok_session_args(bridge_options) ++
        maybe_model_args(bridge_options, "VIBE_GROK_MODEL", "--model") ++
        maybe_grok_always_approve_args(permission_mode)

    run_command(worker, executable, args, opts)
  end

  # Fresh by default: mobile Claude/Codex chats are scratch sessions unless the user
  # explicitly opens a History session, which carries `agentBridgeResumeSessionId`.
  defp claude_session_args(bridge_options) do
    case explicit_resume_session_id(bridge_options) do
      session_id when is_binary(session_id) -> ["--resume", session_id]
      _ -> []
    end
  end

  defp grok_session_args(bridge_options) do
    case explicit_resume_session_id(bridge_options) do
      session_id when is_binary(session_id) -> ["--resume", session_id]
      _ -> []
    end
  end

  defp grok_effort_args(options) do
    case normalize_reasoning_effort(option_value(options, "reasoningEffort"), :grok) do
      nil -> []
      effort -> ["--reasoning-effort", effort]
    end
  end

  defp maybe_grok_always_approve_args(mode) when mode in ["bypassPermissions", "auto"],
    do: ["--always-approve"]

  defp maybe_grok_always_approve_args(_), do: []

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

        bridge_options = Keyword.get(opts, :bridge_metadata) || %{}

        if ok && explicit_resume_session_id(bridge_options) do
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
          profile_image: worker.avatar_url,
          is_agent: true,
          tier: worker.tier,
          inserted_at: now,
          updated_at: now
        }
      ],
      conflict_target: [:id],
      on_conflict: [
        set: [
          updated_at: now,
          username: worker.username,
          name: worker.name,
          profile_image: worker.avatar_url,
          is_agent: true,
          tier: worker.tier
        ]
      ]
    )

    ensure_agent_gold_badge(worker)

    :ok
  rescue
    error -> {:error, error}
  end

  defp ensure_agent_gold_badge(worker) do
    case Badges.award_badge(worker.agent_user_id, "gold", "system") do
      {:ok, _badge} ->
        :ok

      {:error, changeset} ->
        Logger.warning(
          "[LocalAgentWorker] failed to seed gold badge for #{worker.handle}: #{inspect(changeset.errors)}"
        )
    end
  end

  defp normalize_prompt(_worker, prompt) do
    cleaned =
      prompt
      |> to_string()
      |> String.replace(~r/(?:^|\s)@(codex|claude|grok)\b/i, " ")
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

  defp maybe_model_args(options, env_name, flag) do
    case normalize_string(option_value(options, "model")) ||
           normalize_string(System.get_env(env_name)) do
      nil -> []
      model -> [flag, model]
    end
  end

  defp maybe_advisor_args(options) do
    case normalize_string(option_value(options, "advisor")) ||
           normalize_string(System.get_env("VIBE_CLAUDE_ADVISOR")) ||
           normalize_string(System.get_env("VIBE_CLAUDE_ADVISOR_MODEL")) do
      nil -> []
      advisor -> ["--advisor", advisor]
    end
  end

  defp claude_effort_args(options) do
    case normalize_reasoning_effort(option_value(options, "reasoningEffort"), :claude) do
      nil -> []
      effort -> ["--effort", effort]
    end
  end

  defp codex_reasoning_args(options) do
    case normalize_reasoning_effort(option_value(options, "reasoningEffort"), :codex) do
      nil -> []
      effort -> ["-c", "model_reasoning_effort=\"#{effort}\""]
    end
  end

  defp normalize_reasoning_effort(value, provider) do
    value =
      value
      |> normalize_string()
      |> case do
        nil -> nil
        raw -> raw |> String.downcase() |> String.replace(["-", " "], "_")
      end

    case {provider, value} do
      {_, nil} -> nil
      {:claude, value} when value in ["low", "medium", "high", "xhigh"] -> value
      {:claude, value} when value in ["extra_high", "max"] -> "xhigh"
      {:codex, value} when value in ["low", "medium", "high"] -> value
      {:codex, value} when value in ["xhigh", "extra_high", "max"] -> "high"
      {:grok, value} when value in ["low", "medium", "high"] -> value
      {:grok, value} when value in ["xhigh", "extra_high", "max"] -> "high"
      _ -> nil
    end
  end

  defp option_value(options, key) when is_map(options) do
    options[key] || options[camelize_key(key)] || options[String.to_atom(key)]
  end

  defp option_value(_options, _key), do: nil

  defp explicit_resume_session_id(options) do
    [
      "agentBridgeResumeSessionId",
      "resumeSessionId",
      "resume_session_id",
      "sessionId",
      "session_id"
    ]
    |> Enum.find_value(fn key -> normalize_string(option_value(options, key)) end)
  end

  defp camelize_key("reasoningEffort"), do: "agentBridgeReasoningEffort"
  defp camelize_key("model"), do: "agentBridgeModel"
  defp camelize_key("advisor"), do: "agentBridgeAdvisor"
  defp camelize_key("resumeSessionId"), do: "agentBridgeResumeSessionId"
  defp camelize_key("sessionId"), do: "agentBridgeSessionId"
  defp camelize_key(key), do: key

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
    text = extract_worker_text(worker, decoded, output)

    %{
      text: text,
      # Kept so the LIVE stream path can rebuild the interleaved feed WITH the
      # in-progress answer tail (build_progress_nodes drops the summary block —
      # see live_progress_nodes/2).
      decoded: decoded,
      tool_events: tool_events,
      available_tools: available_tools_from_decoded(worker, decoded),
      raw_event_count: length(decoded),
      progress_nodes: build_progress_nodes(worker, decoded, tool_events, text)
    }
  end

  # Progress nodes for the "Worked …" card. For Claude/Codex we INTERLEAVE the
  # agent's working text (the running narration it emits between tool calls) with
  # its tool steps in chronological order, so the collapsed card reads top-down
  # exactly as the agent worked (text → edit → read → text …). The FINAL summary
  # block is excluded — it renders as the message body OUTSIDE the card.
  defp build_progress_nodes(%{handle: "claude"}, decoded, tool_events, summary_text) do
    interleaved_claude_progress_nodes(decoded, tool_events, summary_text)
  end

  defp build_progress_nodes(%{handle: "codex"}, decoded, tool_events, summary_text) do
    interleaved_codex_progress_nodes(decoded, tool_events, summary_text)
    |> Enum.take(@max_tool_events)
  end

  defp build_progress_nodes(%{handle: "grok"}, decoded, tool_events, summary_text) do
    interleaved_grok_progress_nodes(decoded, tool_events, summary_text)
  end

  defp build_progress_nodes(%{handle: "agy"}, decoded, tool_events, summary_text) do
    interleaved_grok_progress_nodes(decoded, tool_events, summary_text)
    |> rewrite_progress_node_provider_prefix("grok", "agy")
  end

  defp build_progress_nodes(_worker, _decoded, tool_events, _summary_text) do
    progress_nodes_from_events(tool_events)
  end

  defp rewrite_progress_node_provider_prefix(nodes, from, to) when is_list(nodes) do
    Enum.map(nodes, fn
      %{"id" => id} = node when is_binary(id) ->
        Map.put(node, "id", String.replace_prefix(id, from <> "-", to <> "-"))

      other ->
        other
    end)
  end

  defp rewrite_progress_node_provider_prefix(nodes, _from, _to), do: nodes

  # Grok live stream is a MIX of:
  #   stdout streaming-json: {"type":"thought"|"text"|"end", "data":...}
  #   bridge-injected tools from updates.jsonl: {"type":"tool_use"|"tool_result", ...}
  #   throttled vibe_thinking ticker lines
  # Walk chronologically. Text/thinking use *segment* ids (`grok-text-0`,
  # `grok-thinking-1`, …) so a tool between narrations does not pin later prose
  # back to the first text slot (the "all tools on top, all text at bottom" bug).
  # Bump `seg` after each tool so the next thought/text segment appends after it.
  defp interleaved_grok_progress_nodes(decoded, tool_events, summary_text) do
    summary_norm = summary_text |> to_string() |> String.trim()
    tool_by_id = Map.new(tool_events || [], fn ev -> {ev["id"], ev} end)

    settled =
      Enum.any?(decoded, fn
        %{"type" => "end"} -> true
        _ -> false
      end)

    think_status = if settled, do: "done", else: "streaming"
    text_status = if settled, do: "done", else: "streaming"

    initial = %{
      nodes: [],
      thought: "",
      answer: "",
      used_tools: MapSet.new(),
      thought_flushed: false,
      # Segment counter: same seg for continuous thought+text; tools bump it.
      seg: 0,
      # True after a tool/compacting node so the next thought/text starts a new seg.
      need_new_seg: false
    }

    state =
      Enum.reduce(decoded, initial, fn event, st ->
        cond do
          not is_map(event) ->
            st

          event["type"] == "thought" and is_binary(event["data"]) ->
            st
            |> grok_begin_thought_phase()
            |> Map.update!(:thought, &(&1 <> event["data"]))
            |> Map.put(:thought_flushed, false)

          event["type"] == "text" and is_binary(event["data"]) ->
            st
            |> grok_flush_thought_node(think_status)
            |> grok_begin_text_phase()
            |> Map.update!(:answer, &join_grok_text_chunks([&1, event["data"]]))

          event["type"] == "tool_use" ->
            id = normalize_string(event["id"]) || unique_event_id("grok-tool", length(st.nodes))

            st
            |> grok_flush_thought_node(think_status)
            |> grok_flush_answer_node(summary_norm, text_status)
            |> grok_put_tool_node(id, event, tool_by_id)

          event["type"] == "tool_result" ->
            id = normalize_string(event["tool_use_id"] || event["id"])
            grok_mark_tool_result(st, id, event)

          # Live compacting signals (bridge may inject these from updates.jsonl).
          event["type"] in ["compacting", "auto_compact_started"] ->
            grok_put_compacting_node(st, "running", event)

          event["type"] in ["compacted", "auto_compact_completed"] ->
            grok_put_compacting_node(st, "done", event)

          is_binary(event["thought"]) and event["type"] not in ["text", "end"] ->
            st
            |> grok_begin_thought_phase()
            |> Map.update!(:thought, &(&1 <> event["thought"]))
            |> Map.put(:thought_flushed, false)

          is_binary(event["text"]) and event["type"] not in ["thought", "end", "tool_use", "tool_result"] ->
            st
            |> grok_flush_thought_node(think_status)
            |> grok_begin_text_phase()
            |> Map.update!(:answer, &join_grok_text_chunks([&1, event["text"]]))

          true ->
            # Claude-shaped content blocks injected for tools (optional path).
            blocks = content_blocks_from_event(event)

            Enum.reduce(blocks, st, fn block, inner ->
              case block do
                %{"type" => "tool_use"} = tool_block ->
                  id =
                    normalize_string(tool_block["id"]) ||
                      unique_event_id("grok-tool", length(inner.nodes))

                  inner
                  |> grok_flush_thought_node(think_status)
                  |> grok_flush_answer_node(summary_norm, text_status)
                  |> grok_put_tool_node(id, tool_block, tool_by_id)

                %{"type" => "tool_result"} = result_block ->
                  id = normalize_string(result_block["tool_use_id"] || result_block["id"])
                  grok_mark_tool_result(inner, id, result_block)

                %{"type" => "thinking", "thinking" => body} when is_binary(body) ->
                  inner
                  |> grok_begin_thought_phase()
                  |> Map.update!(:thought, &(&1 <> body))
                  |> Map.put(:thought_flushed, false)

                %{"type" => "text", "text" => body} when is_binary(body) ->
                  inner
                  |> grok_flush_thought_node(think_status)
                  |> grok_begin_text_phase()
                  |> Map.update!(:answer, &join_grok_text_chunks([&1, body]))

                _ ->
                  inner
              end
            end)
        end
      end)

    # Keep multi-segment interleave live AND settled. Final summary body (when equal
    # to summary_norm) is still dropped inside grok_flush_answer_node.
    state
    |> grok_flush_thought_node(think_status)
    |> grok_flush_answer_node(summary_norm, text_status)
    |> Map.get(:nodes)
  end

  # After tools (or when re-entering thought after flushed narration), advance seg
  # so the next thought/text node appends instead of upserting an earlier slot.
  defp grok_begin_thought_phase(st) do
    st =
      if String.trim(st.answer) != "" do
        # Thought after open text without a tool — seal text on current seg, then bump.
        st
        |> grok_flush_answer_node("", "done")
        |> Map.put(:answer, "")
        |> Map.put(:need_new_seg, true)
      else
        st
      end

    if st.need_new_seg or (st.thought_flushed and String.trim(st.thought) == "") do
      %{st | seg: st.seg + 1, need_new_seg: false, thought_flushed: false}
    else
      st
    end
  end

  defp grok_begin_text_phase(st) do
    if st.need_new_seg do
      %{st | seg: st.seg + 1, need_new_seg: false}
    else
      st
    end
  end

  defp grok_flush_thought_node(st, status) do
    body = String.trim(st.thought)

    cond do
      body == "" and not st.thought_flushed ->
        st

      body == "" ->
        st

      true ->
        tokens = max(1, div(String.length(body), 4))
        seg = st.seg

        node = %{
          "id" => "grok-thinking-#{seg}",
          "label" => "Thinking",
          "status" => status,
          "kind" => "thinking",
          "depth" => 0,
          "tokens" => tokens,
          # Full CoT for the phone thinking sheet (tap compact row → expand/sheet).
          "detail" => clip_text_node(body),
          "output" => clip_text_node(body)
        }

        nodes = upsert_progress_node(st.nodes, node)
        %{st | nodes: nodes, thought_flushed: true}
    end
  end

  defp grok_flush_answer_node(st, summary_norm, status) do
    body = String.trim(st.answer)

    cond do
      body == "" ->
        st

      body == summary_norm and summary_norm != "" ->
        # Finished summary re-renders as the message body outside the card.
        st

      true ->
        seg = st.seg

        node = %{
          "id" => "grok-text-#{seg}",
          "label" => clip_text_node(body),
          "status" => status,
          "kind" => "text",
          "depth" => 0,
          "detail" => clip_text_node(body)
        }

        %{st | nodes: upsert_progress_node(st.nodes, node)}
    end
  end

  defp grok_put_tool_node(st, id, tool_block, tool_by_id) do
    if MapSet.member?(st.used_tools, id) do
      st
    else
      event =
        Map.get(tool_by_id, id) ||
          %{
            "id" => id,
            "tool" => normalize_string(tool_block["name"]) || "tool",
            "label" =>
              tool_label(
                "Grok",
                normalize_string(tool_block["name"]) || "tool",
                tool_block["input"] || %{}
              ),
            "status" => "running",
            "input" => safe_payload(tool_block["input"] || %{}),
            "providerEventType" => "tool_use"
          }
          |> put_node_shape(
            normalize_string(tool_block["name"]) || "tool",
            tool_block["input"] || %{}
          )

      node = tool_event_to_node(event, length(st.nodes))
      # Next thought/text must not upsert into the pre-tool segment.
      %{
        st
        | nodes: st.nodes ++ [node],
          used_tools: MapSet.put(st.used_tools, id),
          need_new_seg: true,
          thought: "",
          answer: "",
          thought_flushed: false
      }
    end
  end

  defp grok_put_compacting_node(st, status, event) when is_map(event) do
    id = normalize_string(event["id"]) || "grok-compacting-#{st.seg}"
    tokens_before = event["tokens_before"] || event["tokensBefore"]
    tokens_after = event["tokens_after"] || event["tokensAfter"]

    label =
      cond do
        status == "done" and is_integer(tokens_before) and is_integer(tokens_after) ->
          "Compacted context · #{tokens_before} → #{tokens_after} tokens"

        status == "done" ->
          "Compacted conversation"

        true ->
          "Compacting conversation…"
      end

    node = %{
      "id" => id,
      "label" => label,
      "status" => status,
      "kind" => "compacting",
      "depth" => 0
    }

    nodes = upsert_progress_node(st.nodes, node)

    %{
      st
      | nodes: nodes,
        need_new_seg: true,
        thought: "",
        answer: "",
        thought_flushed: false
    }
  end

  defp grok_put_compacting_node(st, _status, _event), do: st

  defp grok_mark_tool_result(st, nil, _event), do: st

  defp grok_mark_tool_result(st, id, event) do
    failed =
      event["is_error"] == true || event["isError"] == true ||
        to_string(event["status"] || "") in ["error", "failed", "cancelled"]

    status = if failed, do: "error", else: "done"

    nodes =
      Enum.map(st.nodes, fn node ->
        if to_string(node["id"] || "") == id do
          Map.put(node, "status", status)
        else
          node
        end
      end)

    %{st | nodes: nodes}
  end

  # Replace same-id node in place (stable thinking/text across chunks); append if new.
  defp upsert_progress_node(nodes, node) when is_list(nodes) and is_map(node) do
    id = to_string(node["id"] || "")

    case Enum.find_index(nodes, fn n -> to_string(n["id"] || "") == id end) do
      nil ->
        nodes ++ [node]

      idx ->
        List.replace_at(nodes, idx, node)
    end
  end

  defp upsert_progress_node(nodes, _node), do: nodes

  defp interleaved_codex_progress_nodes(decoded, tool_events, summary_text) do
    tool_by_id = Map.new(tool_events, fn ev -> {ev["id"], ev} end)
    summary_norm = summary_text |> to_string() |> String.trim()

    {nodes, used, _text_index, _thinking_count} =
      decoded
      |> Enum.with_index()
      |> Enum.reduce({[], MapSet.new(), 0, 0}, fn {event, index},
                                                  {nodes, used, text_index, thinking_count} ->
        item = codex_event_item(event)

        cond do
          is_map(item) ->
            type = codex_item_type(item) || ""

            cond do
              type == "reasoning" ->
                if thinking_count >= 4 do
                  {nodes, used, text_index, thinking_count}
                else
                  node = %{
                    "id" => "codex-thinking-#{index}",
                    "label" => "Thinking",
                    "status" => "done",
                    "depth" => 0,
                    "kind" => "thinking"
                  }

                  {[node | nodes], used, text_index, thinking_count + 1}
                end

              codex_agent_message?(item) ->
                text = codex_item_text(item)
                trimmed = text |> to_string() |> String.trim()

                if trimmed == "" or trimmed == summary_norm do
                  {nodes, used, text_index, thinking_count}
                else
                  node = %{
                    "id" => "codex-text-#{text_index}",
                    "label" => clip_text_node(text),
                    "status" => "done",
                    "depth" => 0,
                    "kind" => "text"
                  }

                  {[node | nodes], used, text_index + 1, thinking_count}
                end

              type in ["agent_message", "message"] ->
                {nodes, used, text_index, thinking_count}

              true ->
                id = codex_tool_event_id(event, item, index)

                case Map.get(tool_by_id, id) do
                  nil ->
                    {nodes, used, text_index, thinking_count}

                  tool_event ->
                    if MapSet.member?(used, id) do
                      {nodes, used, text_index, thinking_count}
                    else
                      node = tool_event_to_node(tool_event, length(nodes))
                      {[node | nodes], MapSet.put(used, id), text_index, thinking_count}
                    end
                end
            end

          true ->
            {nodes, used, text_index, thinking_count}
        end
      end)

    remaining_tool_nodes =
      tool_events
      |> Enum.reject(fn event -> MapSet.member?(used, event["id"]) end)
      |> Enum.with_index()
      |> Enum.map(fn {event, index} -> tool_event_to_node(event, index) end)

    Enum.reverse(nodes) ++ remaining_tool_nodes
  end

  defp interleaved_claude_progress_nodes(decoded, tool_events, summary_text) do
    tool_by_id = Map.new(tool_events, fn ev -> {ev["id"], ev} end)
    summary_norm = summary_text |> to_string() |> String.trim()

    # Surface bridge-injected compacting events (Claude /compact headless).
    compact_nodes =
      decoded
      |> Enum.reduce([], fn event, acc ->
        cond do
          not is_map(event) ->
            acc

          event["type"] in ["auto_compact_started", "compacting"] ->
            [
              %{
                "id" => normalize_string(event["id"]) || "claude-compacting",
                "label" => "Compacting conversation…",
                "status" => "running",
                "kind" => "compacting",
                "depth" => 0
              }
              | acc
            ]

          event["type"] in ["auto_compact_completed", "compacted"] ->
            [
              %{
                "id" => normalize_string(event["id"]) || "claude-compacting",
                "label" => "Compacted conversation",
                "status" => "done",
                "kind" => "compacting",
                "depth" => 0
              }
              | acc
            ]

          true ->
            acc
        end
      end)
      |> Enum.reverse()

    {nodes, _used, _text_index} =
      decoded
      |> Enum.flat_map(fn event ->
        # Keep the per-event parent_tool_use_id so a subagent's narration/thinking
        # rides depth 1 (its own view), not the main feed.
        parent = normalize_string(event["parent_tool_use_id"])
        event |> content_blocks_from_event() |> Enum.map(fn block -> {block, parent} end)
      end)
      |> Enum.reduce({[], MapSet.new(), 0}, fn {block, parent}, {nodes, used, ti} ->
        case block do
          %{"type" => "text", "text" => raw_text} when is_binary(raw_text) ->
            trimmed = String.trim(raw_text)

            # Skip empty chatter and the final summary (it's the body, not a step).
            if trimmed == "" or trimmed == summary_norm do
              {nodes, used, ti}
            else
              node =
                %{
                  "id" => "worker-text-#{ti}",
                  "label" => clip_text_node(raw_text),
                  "status" => "done",
                  "depth" => 0,
                  "kind" => "text"
                }
                |> put_subagent_depth(parent)

              {[node | nodes], used, ti + 1}
            end

          %{"type" => "tool_use"} = tool_block ->
            id = normalize_string(tool_block["id"])

            case id && Map.get(tool_by_id, id) do
              nil ->
                {nodes, used, ti}

              event ->
                if MapSet.member?(used, id) do
                  {nodes, used, ti}
                else
                  {[tool_event_to_node(event, length(nodes)) | nodes], MapSet.put(used, id), ti}
                end
            end

          _ ->
            if block["type"] == "thinking" do
              node =
                %{
                  "id" => "claude-thinking-#{ti}",
                  "label" => "Thinking",
                  "status" => "done",
                  "depth" => 0,
                  "kind" => "thinking"
                }
                |> put_subagent_depth(parent)

              {[node | nodes], used, ti + 1}
            else
              {nodes, used, ti}
            end
        end
      end)

    # Compacting nodes lead (or trail) so the header/cell can show the state.
    compact_nodes ++ Enum.reverse(nodes)
  end

  # The agent's working text can be long; keep enough to read the card without
  # bloating the (plaintext) progressNodes payload.
  defp clip_text_node(text) do
    text = String.trim(to_string(text))

    if String.length(text) > 4000 do
      String.slice(text, 0, 4000) <> "…"
    else
      text
    end
  end

  defp tool_event_to_node(event, index) do
    %{
      "id" => event["id"] || unique_event_id("worker-progress", index),
      "label" => event["label"] || event["tool"] || "Working...",
      "status" => event["status"] || "running",
      "depth" => 0
    }
    |> copy_node_shape(event)
  end

  defp extract_worker_text(%{handle: "codex"}, decoded, output) do
    extract_codex_text(decoded) || plain_output_text(decoded, output)
  end

  defp extract_worker_text(%{handle: "claude"}, decoded, output) do
    extract_claude_text(decoded) || plain_output_text(decoded, output)
  end

  defp extract_worker_text(%{handle: "grok"}, decoded, output) do
    extract_grok_text(decoded) || plain_output_text(decoded, output)
  end

  defp extract_worker_text(%{handle: "agy"}, decoded, output) do
    extract_grok_text(decoded) || plain_output_text(decoded, output)
  end

  defp extract_worker_text(_worker, decoded, output), do: plain_output_text(decoded, output)

  defp extract_grok_text(decoded) do
    streaming =
      decoded
      |> Enum.filter(fn
        %{"type" => "text", "data" => data} when is_binary(data) -> true
        _ -> false
      end)
      |> Enum.map(& &1["data"])
      |> join_grok_text_chunks()
      |> normalize_string()

    streaming ||
      decoded
      |> Enum.reduce(nil, fn event, acc ->
        cond do
          not is_map(event) ->
            acc

          is_binary(event["text"]) and event["type"] not in ["thought", "end"] ->
            event["text"]

          is_binary(event["result"]) ->
            event["result"]

          true ->
            acc
        end
      end)
      |> normalize_string()
  end

  # Grok often emits sentence-sized `text` chunks. Blind join produced
  # "issue.This is not…" in the phone body. Insert space or paragraph break
  # when adjacent chunks lack whitespace at the boundary.
  defp join_grok_text_chunks([]), do: ""
  defp join_grok_text_chunks(chunks) when is_list(chunks) do
    Enum.reduce(chunks, "", fn chunk, acc ->
      chunk = to_string(chunk)

      cond do
        chunk == "" ->
          acc

        acc == "" ->
          chunk

        true ->
          a = String.last(acc) || ""
          b = String.first(chunk) || ""
          a_ws? = a != "" and String.trim(a) == ""
          b_ws? = b != "" and String.trim(b) == ""
          punct_b? = b in [".", ",", ";", ":", "!", "?", ")", "]", "}"]
          open_b? = b in ["(", "[", "{", "/", "-"]
          upper_b? = b >= "A" and b <= "Z"

          sentence_break? = a in [".", "!", "?"] and upper_b?

          sep =
            cond do
              a_ws? or b_ws? -> ""
              sentence_break? -> "\n\n"
              punct_b? or open_b? -> ""
              true -> " "
            end

          acc <> sep <> chunk
      end
    end)
  end

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

  # The `codex exec --json` stdout is the thread-item streaming format
  # (thread.started / turn.* / item.{started,updated,completed} / error).
  # See docs/agent-payload-shapes.md. The assistant reply is the last
  # `agent_message` item's `text`; on failure the envelope `error`/`turn.failed`
  # message surfaces instead (e.g. usage-limit caps).
  defp extract_codex_text(decoded) do
    decoded
    |> Enum.reduce(nil, fn event, acc ->
      item = codex_event_item(event) || event

      cond do
        codex_agent_message?(item) ->
          codex_item_text(item) || acc

        codex_envelope_error_message(event) != nil ->
          codex_envelope_error_message(event)

        true ->
          acc
      end
    end)
    |> normalize_string()
  end

  # Top-level `{"type":"error","message":…}` or `{"type":"turn.failed","error":{"message":…}}`.
  defp codex_envelope_error_message(event) when is_map(event) do
    type = normalize_string(event["type"]) || ""

    cond do
      type in ["error", "turn.failed", "thread.failed"] ->
        normalize_string(event["message"]) ||
          normalize_string(get_in(event, ["error", "message"]))

      true ->
        nil
    end
  end

  defp codex_envelope_error_message(_), do: nil

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

  defp tool_events_from_decoded(%{handle: "grok"}, decoded) do
    decoded
    |> grok_tool_events()
    |> Enum.take(@max_tool_events)
  end

  defp tool_events_from_decoded(%{handle: "agy"}, decoded) do
    decoded
    |> grok_tool_events()
    |> Enum.map(fn ev ->
      ev
      |> Map.put("provider", "agy")
      |> Map.update("label", nil, fn
        label when is_binary(label) -> String.replace(label, "Grok", "Agy")
        other -> other
      end)
    end)
    |> Enum.take(@max_tool_events)
  end

  defp tool_events_from_decoded(_worker, _decoded), do: []

  # Bridge injects tool_use / tool_result NDJSON from the Grok session updates tail.
  defp grok_tool_events(decoded) do
    {events_by_id, order} =
      Enum.reduce(decoded, {%{}, []}, fn event, {events_by_id, order} = acc ->
        cond do
          not is_map(event) ->
            acc

          event["type"] == "tool_use" ->
            id = normalize_string(event["id"]) || unique_event_id("grok-tool", length(order))
            tool = normalize_string(event["name"]) || "tool"
            input = event["input"] || %{}

            ev =
              %{
                "id" => id,
                "provider" => "grok",
                "tool" => tool,
                "label" => tool_label("Grok", tool, input),
                "status" => "running",
                "input" => safe_payload(input),
                "providerEventType" => "tool_use"
              }
              |> put_node_shape(tool, input)

            {Map.put(events_by_id, id, ev), append_once(order, id)}

          event["type"] == "tool_result" ->
            id = normalize_string(event["tool_use_id"] || event["id"])

            if id && Map.has_key?(events_by_id, id) do
              failed =
                event["is_error"] == true || event["isError"] == true ||
                  to_string(event["status"] || "") in ["error", "failed", "cancelled"]

              prev = Map.fetch!(events_by_id, id)

              updated =
                prev
                |> Map.put("status", if(failed, do: "error", else: "done"))
                |> Map.put(
                  "output",
                  event["content"] || event["output"] || prev["output"]
                )

              {Map.put(events_by_id, id, updated), order}
            else
              acc
            end

          true ->
            # Also accept Claude-shaped content blocks if the bridge ever emits them.
            event
            |> content_blocks_from_event()
            |> Enum.reduce(acc, fn block, inner ->
              accumulate_claude_tool_block(block, nil, inner)
            end)
        end
      end)

    order
    |> Enum.uniq()
    |> Enum.map(&Map.fetch!(events_by_id, &1))
  end

  defp claude_tool_events(decoded) do
    {events_by_id, order} =
      Enum.reduce(decoded, {%{}, []}, fn event, acc ->
        # Claude tags every subagent (`Task` tool) event with the parent Task's
        # tool_use id; parent-agent events have it nil. Carry it down so a
        # subagent's own tools land at depth 1 / parentId (grouped under the Task)
        # instead of being flattened into the main feed.
        parent = normalize_string(event["parent_tool_use_id"])

        event
        |> content_blocks_from_event()
        |> Enum.reduce(acc, fn block, inner -> accumulate_claude_tool_block(block, parent, inner) end)
      end)

    order
    |> Enum.uniq()
    |> Enum.map(&Map.fetch!(events_by_id, &1))
  end

  defp accumulate_claude_tool_block(%{"type" => "tool_use"} = block, parent, {events_by_id, order}) do
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
      |> put_subagent_shape(parent)

    {Map.put(events_by_id, id, event), append_once(order, id)}
  end

  defp accumulate_claude_tool_block(%{"type" => "tool_result"} = block, parent, {events_by_id, order}) do
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
         }
         |> put_subagent_shape(parent))
      |> Map.merge(%{
        "status" => status,
        "outputPreview" => safe_text(output),
        "providerEventType" => "tool_result"
      })

    {Map.put(events_by_id, id, event), append_once(order, id)}
  end

  defp accumulate_claude_tool_block(_block, _parent, acc), do: acc

  # Stamp a tool event as a subagent child (depth 1 + parentId) when it carries a
  # parent_tool_use_id; otherwise it is a depth-0 main-feed step.
  defp put_subagent_shape(event, parent) when is_binary(parent) and parent != "" do
    event |> Map.put("depth", 1) |> Map.put("parentId", parent)
  end

  defp put_subagent_shape(event, _parent), do: Map.put_new(event, "depth", 0)

  # Same idea for plain narration/thinking nodes (no tool shape): depth 1 + parentId
  # when produced inside a subagent, depth 0 otherwise.
  defp put_subagent_depth(node, parent) when is_binary(parent) and parent != "" do
    node |> Map.put("depth", 1) |> Map.put("parentId", parent)
  end

  defp put_subagent_depth(node, _parent), do: node

  # Parse the codex thread-item stream into tool events. The discriminator is
  # `item.item_type` (fall back to `item.type`); envelope `error`/`turn.failed`
  # become an error node. agent_message/reasoning are excluded (handled as text).
  defp codex_tool_events(decoded) do
    decoded
    |> Enum.with_index()
    |> Enum.flat_map(fn {event, index} ->
      item = codex_event_item(event)

      cond do
        is_map(item) ->
          type = codex_item_type(item) || ""

          if type in ["agent_message", "reasoning", "message"] do
            []
          else
            [codex_tool_event(event, item, type, index)]
          end

        codex_envelope_error_message(event) != nil ->
          [codex_error_tool_event(event, index)]

        true ->
          []
      end
    end)
    |> compact_tool_events()
  end

  defp codex_event_item(event) when is_map(event) do
    cond do
      is_map(map_value(event, "item")) ->
        map_value(event, "item")

      normalize_string(event["type"]) == "response_item" and is_map(event["payload"]) ->
        event["payload"]

      normalize_string(event["type"]) != "event_msg" and is_map(event["payload"]) and
          codex_known_item_type?(event["payload"]) ->
        event["payload"]

      true ->
        nil
    end
  end

  defp codex_event_item(_), do: nil

  defp codex_item_type(item) when is_map(item) do
    normalize_string(item["item_type"]) || normalize_string(item["type"])
  end

  defp codex_item_type(_), do: nil

  defp codex_known_item_type?(item) when is_map(item) do
    (codex_item_type(item) || "") in [
      "agent_message",
      "message",
      "reasoning",
      "command_execution",
      "file_change",
      "web_search",
      "mcp_tool_call",
      "function_call",
      "function_call_output",
      "custom_tool_call",
      "custom_tool_call_output",
      "todo_list",
      "error"
    ]
  end

  defp codex_known_item_type?(_), do: false

  defp codex_agent_message?(item) when is_map(item) do
    case codex_item_type(item) do
      "agent_message" ->
        true

      "message" ->
        role = item["role"] |> normalize_string() |> then(&(&1 && String.downcase(&1)))
        role in ["assistant", "agent"]

      _ ->
        false
    end
  end

  defp codex_agent_message?(_), do: false

  defp codex_item_text(item) when is_map(item) do
    normalize_string(item["text"]) ||
      normalize_string(item["message"]) ||
      content_blocks_text(item["content"])
  end

  defp codex_item_text(_), do: nil

  defp codex_tool_event_id(event, item, index) do
    normalize_string(item["call_id"]) ||
      normalize_string(item["id"]) ||
      normalize_string(event["id"]) ||
      unique_event_id("codex-tool", index)
  end

  defp codex_tool_event(event, item, type, index) do
    {tool, input, output} = codex_item_fields(type, item)

    %{
      "id" => codex_tool_event_id(event, item, index),
      "provider" => "codex",
      "tool" => tool,
      "label" => tool_label("Codex", tool, input),
      "status" => codex_item_status(event, item),
      "input" => safe_payload(input),
      "outputPreview" => safe_text(output),
      "providerEventType" => normalize_string(event["type"]) || type
    }
    |> put_node_shape(tool, input)
    |> codex_apply_file_change_shape(type, item)
  end

  defp codex_error_tool_event(event, index) do
    message = codex_envelope_error_message(event)

    # Derive a stable id from the message so `error` + `turn.failed` (which carry
    # the same text) collapse into one node via compact_tool_events.
    id =
      case message do
        text when is_binary(text) ->
          "codex-error-" <>
            (:crypto.hash(:md5, text) |> Base.encode16(case: :lower) |> binary_part(0, 8))

        _ ->
          unique_event_id("codex-error", index)
      end

    %{
      "id" => normalize_string(event["id"]) || id,
      "provider" => "codex",
      "tool" => "Error",
      "label" => "Codex error",
      "status" => "failed",
      "input" => %{},
      "outputPreview" => safe_text(message),
      "providerEventType" => normalize_string(event["type"]) || "error",
      "kind" => "error"
    }
  end

  # Map a thread-item type to {tool_name, input_map, output} for rendering.
  defp codex_item_fields("command_execution", item) do
    command = codex_command_string(item)
    output = item["aggregated_output"] || item["stdout"] || item["output"]
    {tool, input} = codex_shell_tool(command)
    {tool, input, output}
  end

  defp codex_item_fields("file_change", item) do
    paths = codex_file_change_paths(item)
    input = %{"file_path" => List.first(paths)}
    input = if length(paths) > 1, do: Map.put(input, "files", paths), else: input
    {codex_file_change_tool(item), input, item["stdout"] || item["output"]}
  end

  defp codex_item_fields("web_search", item) do
    query = normalize_string(item["query"]) || normalize_string(item["action"])
    {"WebSearch", %{"query" => query}, nil}
  end

  defp codex_item_fields("mcp_tool_call", item) do
    tool = normalize_string(item["tool"]) || normalize_string(item["name"]) || "MCP"
    server = normalize_string(item["server"])
    label = if server, do: "#{server}.#{tool}", else: tool

    input =
      cond do
        is_map(item["arguments"]) -> item["arguments"]
        is_binary(item["arguments"]) -> %{"arguments" => item["arguments"]}
        true -> %{}
      end

    {label, input, item["result"] || item["output"] || item["content"]}
  end

  defp codex_item_fields("function_call", item) do
    name = normalize_string(item["name"]) || normalize_string(item["tool"]) || "tool"
    input = codex_decode_arguments(item["arguments"])
    codex_function_fields(name, input)
  end

  defp codex_item_fields("function_call_output", item) do
    output = item["output"] || item["result"] || item["content"]
    {"Tool result", %{}, output}
  end

  defp codex_item_fields("custom_tool_call", item) do
    name = normalize_string(item["name"]) || normalize_string(item["tool"]) || "tool"
    input = codex_decode_arguments(item["input"] || item["arguments"])
    codex_function_fields(name, input)
  end

  defp codex_item_fields("custom_tool_call_output", item) do
    output = item["output"] || item["result"] || item["content"]
    {"Tool result", %{}, output}
  end

  defp codex_item_fields("todo_list", item) do
    {"TodoWrite", %{"todos" => item["items"] || item["todos"] || []}, nil}
  end

  defp codex_item_fields("error", item) do
    {"Error", %{}, item["message"] || item["text"]}
  end

  # Unknown / future item types: best-effort generic mapping.
  defp codex_item_fields(type, item) do
    output = item["output"] || item["result"] || item["content"] || item["text"]

    case codex_command_string(item) do
      nil ->
        tool =
          cond do
            normalize_string(item["name"]) -> normalize_string(item["name"])
            normalize_string(item["tool"]) -> normalize_string(item["tool"])
            type not in [nil, ""] -> codex_titlecase(type)
            true -> "Tool"
          end

        input =
          cond do
            is_map(item["input"]) -> item["input"]
            is_map(item["arguments"]) -> item["arguments"]
            is_binary(item["arguments"]) -> %{"arguments" => item["arguments"]}
            true -> %{}
          end

        {tool, input, output}

      command ->
        {tool, input} = codex_shell_tool(command)
        {tool, input, output}
    end
  end

  # A function/custom tool call: shell tool names (`exec_command`, …) route through
  # the shell classifier so `cat`/`rg`/`sed` read like Claude's Read/Grep; everything
  # else keeps its name-based mapping (apply_patch → Edit, view_image → ViewImage, …).
  defp codex_function_fields(name, input) do
    if codex_shell_tool_name?(name) do
      {tool, shell_input} = codex_shell_tool(codex_command_string(input))
      {tool, shell_input, nil}
    else
      {codex_function_tool_name(name, input), input, nil}
    end
  end

  defp codex_command_string(item) do
    cond do
      is_binary(item["command"]) ->
        normalize_string(item["command"])

      is_list(item["command"]) ->
        item["command"] |> Enum.join(" ") |> normalize_string()

      is_binary(item["cmd"]) ->
        normalize_string(item["cmd"])

      is_map(item["input"]) and is_binary(item["input"]["cmd"]) ->
        normalize_string(item["input"]["cmd"])

      is_map(item["input"]) and is_binary(item["input"]["command"]) ->
        normalize_string(item["input"]["command"])

      true ->
        nil
    end
  end

  # Codex only has a raw shell, so a bare `rg …` / `sed -n …` / `cat …` renders as
  # low-level "Run <shell>" noise — unlike Claude, whose high-level Read/Grep tools
  # give clean "Read foo.swift" / "Search pattern" rows. Classify the command's lead
  # program into the SAME Read/Grep tool shapes so a Codex feed reads like Claude's.
  # Anything unrecognized stays a plain "Run <command>" ({"Bash", …}). Mirrors
  # codexShellDetail in the bridge (agent-bridge/bin/vibe-bridge.js).
  @codex_read_cmds ~w(cat head tail less more bat nl sed)
  @codex_search_cmds ~w(rg grep egrep fgrep ag ack ripgrep)
  @codex_shell_tool_names ~w(exec_command shell local_shell container.exec bash run_command)

  defp codex_shell_tool(command) do
    cmd = command |> to_string() |> String.replace(~r/\s+/, " ") |> String.trim()
    bash = {"Bash", %{"command" => cmd}}

    if cmd == "" do
      bash
    else
      first =
        cmd
        |> codex_unwrap_shell()
        |> String.split(~r/\s*(?:&&|\|\||[|;])\s*/, parts: 2)
        |> List.first()
        |> to_string()

      case first |> codex_shell_tokens() |> codex_strip_shell_prefixes() do
        [] ->
          bash

        [prog | args] ->
          base = prog |> String.split("/") |> List.last() |> String.downcase()

          cond do
            base in @codex_read_cmds -> codex_shell_read_tool(base, args, bash)
            base in @codex_search_cmds -> codex_shell_search_tool(args, bash)
            true -> bash
          end
      end
    end
  end

  defp codex_shell_tool_name?(name), do: to_string(name) in @codex_shell_tool_names

  # `sed` is a "read" only in its common `-n 'A,Bp'` print form; an editing sed
  # (e.g. `sed -i …`) stays a plain command.
  defp codex_shell_read_tool("sed", args, bash) do
    has_range = Enum.any?(args, &Regex.match?(~r/^\d+,\d+p?$/, &1))

    if "-n" in args or has_range do
      codex_shell_read_tool(nil, args, bash)
    else
      bash
    end
  end

  defp codex_shell_read_tool(_prog, args, bash) do
    case codex_last_path_arg(args) do
      nil -> bash
      file -> {"Read", %{"file_path" => file}}
    end
  end

  defp codex_shell_search_tool(args, bash) do
    case codex_search_pattern(args, false) do
      nil -> bash
      pattern -> {"Grep", %{"pattern" => pattern}}
    end
  end

  # Unwrap `bash -lc '<inner>'` / `sh -c "<inner>"` (and strip the inner command's
  # surrounding quotes) so the wrapped program can be classified.
  defp codex_unwrap_shell(cmd) do
    case Regex.run(~r/^(?:\/\S+\/)?(?:bash|sh|zsh)\s+-[a-z]*c\s+(.+)$/i, cmd) do
      [_, inner] -> inner |> String.trim() |> codex_unquote()
      _ -> cmd
    end
  end

  defp codex_unquote(s) do
    first = String.first(s)

    if first in ["\"", "'"] and String.last(s) == first and String.length(s) >= 2 do
      s |> String.slice(1, String.length(s) - 2) |> String.trim()
    else
      s
    end
  end

  # Minimal shell tokenizer: split on unquoted whitespace, strip one layer of
  # single/double quotes (so `rg -n "A|B" path` → ["rg", "-n", "A|B", "path"]).
  defp codex_shell_tokens(command) do
    {toks, cur, started, _quote} =
      command
      |> to_string()
      |> String.graphemes()
      |> Enum.reduce({[], "", false, nil}, fn ch, {toks, cur, started, quote} ->
        cond do
          quote != nil ->
            if ch == quote, do: {toks, cur, true, nil}, else: {toks, cur <> ch, true, quote}

          ch == "\"" or ch == "'" ->
            {toks, cur, true, ch}

          ch == " " or ch == "\t" ->
            if started, do: {[cur | toks], "", false, nil}, else: {toks, cur, false, nil}

          true ->
            {toks, cur <> ch, true, nil}
        end
      end)

    toks = if started, do: [cur | toks], else: toks
    Enum.reverse(toks)
  end

  # Drop leading env assignments (FOO=bar) and `sudo`/`command` prefixes.
  defp codex_strip_shell_prefixes([tok | rest] = tokens) do
    cond do
      Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*=/, tok) -> codex_strip_shell_prefixes(rest)
      tok in ["sudo", "command"] -> codex_strip_shell_prefixes(rest)
      true -> tokens
    end
  end

  defp codex_strip_shell_prefixes([]), do: []

  # Last positional (non-flag, non-numeric-range) argument → the file a read touches.
  defp codex_last_path_arg(args) do
    args
    |> Enum.reverse()
    |> Enum.find(fn a ->
      a != "" and not String.starts_with?(a, "-") and
        not Regex.match?(~r/^\d+(,\d+)?[a-z]?$/i, a)
    end)
  end

  # First positional argument → the pattern a grep/rg searches for (respect `-e PAT`).
  defp codex_search_pattern([], _take_next), do: nil

  defp codex_search_pattern([a | rest], take_next) do
    cond do
      take_next -> a
      a in ["-e", "--regexp", "--regex"] -> codex_search_pattern(rest, true)
      a != "" and not String.starts_with?(a, "-") -> a
      true -> codex_search_pattern(rest, false)
    end
  end

  defp codex_decode_arguments(arguments) when is_map(arguments), do: arguments

  defp codex_decode_arguments(arguments) when is_binary(arguments) do
    cond do
      apply_patch_envelope?(arguments) ->
        codex_apply_patch_input(arguments)

      true ->
        case Jason.decode(arguments) do
          {:ok, decoded} when is_map(decoded) -> decoded
          _ -> %{"arguments" => arguments}
        end
    end
  end

  defp codex_decode_arguments(_), do: %{}

  defp codex_function_tool_name("exec_command", input) do
    if codex_command_string(%{"input" => input}), do: "Bash", else: "exec_command"
  end

  defp codex_function_tool_name("apply_patch", _input), do: "Edit"
  defp codex_function_tool_name("view_image", _input), do: "ViewImage"
  defp codex_function_tool_name(name, _input), do: name

  defp apply_patch_envelope?(value) when is_binary(value) do
    String.contains?(value, "*** Begin Patch") and String.contains?(value, "*** End Patch")
  end

  defp apply_patch_envelope?(_), do: false

  defp codex_apply_patch_input(patch) when is_binary(patch) do
    files = apply_patch_files(patch)
    paths = files |> Enum.map(&normalize_string(&1["path"])) |> Enum.reject(&is_nil/1)

    %{"patch" => patch}
    |> maybe_put("file_path", List.first(paths))
    |> maybe_put("files", if(paths == [], do: nil, else: paths))
    |> maybe_put("patchFiles", if(files == [], do: nil, else: files))
  end

  defp apply_patch_files(patch) when is_binary(patch) do
    {files, current} =
      patch
      |> String.split("\n")
      |> Enum.reduce({[], nil}, fn line, {files, current} ->
        cond do
          path = apply_patch_header_path(line, "*** Add File: ") ->
            {finish_patch_file(files, current), new_patch_file(path, "add")}

          path = apply_patch_header_path(line, "*** Update File: ") ->
            {finish_patch_file(files, current), new_patch_file(path, "update")}

          path = apply_patch_header_path(line, "*** Delete File: ") ->
            {finish_patch_file(files, current), new_patch_file(path, "delete")}

          String.starts_with?(line, "*** End Patch") ->
            {finish_patch_file(files, current), nil}

          is_map(current) and String.starts_with?(line, "+") and
              not String.starts_with?(line, "+++") ->
            {files, Map.update!(current, "additions", &(&1 + 1))}

          is_map(current) and String.starts_with?(line, "-") and
              not String.starts_with?(line, "---") ->
            {files, Map.update!(current, "deletions", &(&1 + 1))}

          true ->
            {files, current}
        end
      end)

    files
    |> finish_patch_file(current)
    |> Enum.reverse()
  end

  defp apply_patch_files(_), do: []

  defp apply_patch_header_path(line, prefix) do
    if String.starts_with?(line, prefix) do
      line
      |> String.replace(prefix, "", global: false)
      |> normalize_string()
    end
  end

  defp new_patch_file(path, action) do
    %{
      "path" => path,
      "action" => action,
      "additions" => 0,
      "deletions" => 0
    }
  end

  defp finish_patch_file(files, %{"path" => path} = current) when is_binary(path) do
    [current | files]
  end

  defp finish_patch_file(files, _), do: files

  defp patch_files_from_input(input) when is_map(input) do
    cond do
      is_list(input["patchFiles"]) ->
        input["patchFiles"]
        |> Enum.map(&normalize_patch_file/1)
        |> Enum.reject(&is_nil/1)

      apply_patch_envelope?(input["patch"]) ->
        apply_patch_files(input["patch"])

      apply_patch_envelope?(input["arguments"]) ->
        apply_patch_files(input["arguments"])

      is_list(input["files"]) ->
        input["files"]
        |> Enum.map(&normalize_patch_file/1)
        |> Enum.reject(&is_nil/1)

      true ->
        []
    end
  end

  defp patch_files_from_input(_), do: []

  defp normalize_patch_file(%{"path" => path} = file) do
    case normalize_string(path) do
      nil ->
        nil

      normalized_path ->
        %{
          "path" => normalized_path,
          "action" => normalize_string(file["action"]),
          "additions" => normalize_runtime_int(file["additions"]) || 0,
          "deletions" => normalize_runtime_int(file["deletions"]) || 0
        }
    end
  end

  defp normalize_patch_file(path) when is_binary(path) do
    case normalize_string(path) do
      nil -> nil
      normalized_path -> %{"path" => normalized_path, "additions" => 0, "deletions" => 0}
    end
  end

  defp normalize_patch_file(_), do: nil

  defp first_patch_path(input) do
    input
    |> patch_files_from_input()
    |> Enum.find_value(&normalize_string(&1["path"]))
  end

  defp patch_target(input) do
    files = patch_files_from_input(input)

    case files do
      [] ->
        nil

      [file] ->
        file["path"] |> normalize_string() |> target_basename()

      files ->
        "#{length(files)} files"
    end
  end

  defp apply_patch_stats(input) when is_map(input) do
    files = patch_files_from_input(input)

    if files == [] do
      nil
    else
      Enum.reduce(files, {0, 0}, fn file, {added, removed} ->
        {added + (normalize_runtime_int(file["additions"]) || 0),
         removed + (normalize_runtime_int(file["deletions"]) || 0)}
      end)
    end
  end

  defp apply_patch_stats(_), do: nil

  defp codex_file_change_paths(item) do
    case item["changes"] do
      changes when is_list(changes) ->
        changes
        |> Enum.map(fn
          %{"path" => path} -> normalize_string(path)
          path when is_binary(path) -> normalize_string(path)
          _ -> nil
        end)
        |> Enum.reject(&is_nil/1)

      _ ->
        [normalize_string(item["path"]) || normalize_string(item["file_path"])]
        |> Enum.reject(&is_nil/1)
    end
  end

  # If every change is an add ⇒ Write (create); otherwise Edit.
  defp codex_file_change_tool(item) do
    kinds =
      case item["changes"] do
        changes when is_list(changes) ->
          Enum.map(changes, fn
            %{"kind" => kind} -> normalize_string(kind)
            _ -> nil
          end)

        _ ->
          []
      end
      |> Enum.reject(&is_nil/1)

    cond do
      kinds != [] and Enum.all?(kinds, &(&1 == "add")) -> "Write"
      true -> "Edit"
    end
  end

  # file_change items carry no inline old/new text, so put_node_shape can't infer
  # +N/−M. Pin the node kind/target from the change list directly.
  defp codex_apply_file_change_shape(event, "file_change", item) do
    paths = codex_file_change_paths(item)
    target = paths |> List.first() |> codex_basename()

    target =
      cond do
        length(paths) > 1 -> "#{length(paths)} files"
        true -> target
      end

    kind = if codex_file_change_tool(item) == "Write", do: "write", else: "edit"

    event
    |> Map.put("kind", kind)
    |> maybe_put("target", target)
  end

  defp codex_apply_file_change_shape(event, _type, _item), do: event

  defp codex_basename(nil), do: nil
  defp codex_basename(path) when is_binary(path), do: Path.basename(path)

  defp codex_titlecase(type) do
    type
    |> String.replace("_", " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp codex_item_status(event, item) do
    envelope = (normalize_string(event["type"]) || "") |> String.downcase()
    item_type = (codex_item_type(item) || "") |> String.downcase()
    item_status = (normalize_string(item["status"]) || "") |> String.downcase()
    exit_code = item["exit_code"]

    cond do
      is_integer(exit_code) and exit_code != 0 ->
        "failed"

      String.contains?(item_status, ["fail", "error", "abort", "interrupt", "not_found"]) ->
        "failed"

      envelope in ["turn.failed", "error", "thread.failed"] ->
        "failed"

      item_type in ["function_call_output", "custom_tool_call_output"] ->
        "done"

      String.contains?(item_status, ["complete", "done", "success"]) ->
        "done"

      envelope in ["item.completed", "turn.completed"] ->
        "done"

      is_integer(exit_code) and exit_code == 0 ->
        "done"

      String.contains?(item_status, ["progress", "running", "start", "pending"]) ->
        "running"

      envelope in ["item.started", "item.updated"] ->
        "running"

      true ->
        "running"
    end
  end

  defp compact_tool_events(events) do
    {events_by_id, order} =
      Enum.reduce(events, {%{}, []}, fn event, {events_by_id, order} ->
        id = event["id"]
        merged = merge_tool_event(Map.get(events_by_id, id), event)

        {Map.put(events_by_id, id, merged), append_once(order, id)}
      end)

    order
    |> Enum.uniq()
    |> Enum.map(&Map.fetch!(events_by_id, &1))
  end

  defp merge_tool_event(nil, event), do: event

  defp merge_tool_event(existing, event) do
    Map.merge(existing, event, fn
      "tool", old, "Tool result" -> old
      "label", old, new -> if generic_tool_result_label?(new), do: old, else: new
      "input", old, new when is_map(new) and map_size(new) == 0 -> old
      "kind", old, "tool" -> old
      "kind", old, nil -> old
      "target", old, nil -> old
      _key, _old, new -> new
    end)
  end

  defp generic_tool_result_label?(value) when is_binary(value) do
    String.downcase(value) in ["tool result", "codex tool result"]
  end

  defp generic_tool_result_label?(_), do: false

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
    |> Enum.map(fn {event, index} -> tool_event_to_node(event, index) end)
  end

  defp progress_nodes_with_runtime(nodes, nil), do: nodes

  defp progress_nodes_with_runtime(nodes, runtime) when is_map(runtime) do
    runtime_nodes = runtime_progress_nodes(runtime)
    Enum.take(nodes ++ runtime_nodes, @max_tool_events + @max_runtime_files + 1)
  end

  defp runtime_progress_nodes(runtime) do
    diff = runtime["diff"] || %{}

    files =
      case diff["files"] do
        value when is_list(value) -> value
        _ -> []
      end

    task_id = runtime["taskId"] || "bridge-runtime"
    additions = normalize_runtime_int(diff["additions"]) || 0
    deletions = normalize_runtime_int(diff["deletions"]) || 0
    files_changed = normalize_runtime_int(diff["filesChanged"]) || length(files)

    summary =
      if files_changed > 0 do
        [
          %{
            "id" => "#{task_id}-diff-summary",
            "label" => "#{files_changed} file(s) changed",
            "status" => runtime["status"] || "done",
            "depth" => 0,
            "kind" => "diff",
            "added" => additions,
            "removed" => deletions
          }
        ]
      else
        []
      end

    file_nodes =
      files
      |> Enum.take(10)
      |> Enum.with_index()
      |> Enum.map(fn {file, index} ->
        path = file["path"] || file["name"] || "file"

        %{
          "id" => "#{task_id}-file-#{index}",
          "label" => runtime_file_label(file),
          "status" => runtime["status"] || "done",
          "depth" => 1,
          "kind" => "edit",
          "target" => Path.basename(to_string(path)),
          "added" => normalize_runtime_int(file["additions"]) || 0,
          "removed" => normalize_runtime_int(file["deletions"]) || 0
        }
      end)

    summary ++ file_nodes
  end

  defp runtime_file_label(file) when is_map(file) do
    path = normalize_string(file["path"]) || normalize_string(file["name"]) || "file"
    status = normalize_string(file["status"]) || "M"
    "#{status} #{path}"
  end

  defp normalize_runtime_payload(runtime) when is_map(runtime) do
    diff = runtime["diff"] || runtime[:diff] || %{}
    controls = runtime["controls"] || runtime[:controls] || %{}

    %{}
    |> maybe_put(
      "taskId",
      normalize_string(runtime["taskId"] || runtime[:taskId] || runtime["task_id"])
    )
    |> maybe_put("provider", normalize_string(runtime["provider"] || runtime[:provider]))
    |> maybe_put("status", normalize_string(runtime["status"] || runtime[:status]))
    |> maybe_put(
      "repoId",
      normalize_string(runtime["repoId"] || runtime[:repoId] || runtime["repo_id"])
    )
    |> maybe_put(
      "repoName",
      normalize_string(runtime["repoName"] || runtime[:repoName] || runtime["repo_name"])
    )
    |> maybe_put("cwd", normalize_string(runtime["cwd"] || runtime[:cwd]))
    |> maybe_put(
      "workMode",
      normalize_string(runtime["workMode"] || runtime[:workMode] || runtime["work_mode"])
    )
    |> maybe_put(
      "durationMs",
      normalize_runtime_int(runtime["durationMs"] || runtime[:durationMs])
    )
    |> maybe_put("dirtyBefore", runtime_bool(runtime["dirtyBefore"] || runtime[:dirtyBefore]))
    |> maybe_put(
      "dirtyBeforeCount",
      normalize_runtime_int(runtime["dirtyBeforeCount"] || runtime[:dirtyBeforeCount])
    )
    |> maybe_put(
      "exitStatus",
      normalize_runtime_int(runtime["exitStatus"] || runtime[:exitStatus])
    )
    |> maybe_put("command", normalize_runtime_command(runtime["command"] || runtime[:command]))
    |> maybe_put("diff", normalize_runtime_diff(diff))
    |> maybe_put("controls", normalize_runtime_controls(controls))
  end

  defp normalize_runtime_payload(_), do: nil

  # The E2E runtime blob is opaque ciphertext (key lives only on the bridge +
  # phone). Accept only the expected envelope ("arte1.") within a sane size;
  # never inspect, parse, or log the contents.
  defp normalize_runtime_enc(value) when is_binary(value) do
    if String.starts_with?(value, "arte1.") and byte_size(value) <= 200_000 do
      value
    else
      nil
    end
  end

  defp normalize_runtime_enc(_), do: nil

  defp normalize_runtime_command(command) when is_map(command) do
    %{}
    |> maybe_put("executable", normalize_string(command["executable"] || command[:executable]))
    |> maybe_put("display", normalize_string(command["display"] || command[:display]))
    |> maybe_put("args", normalize_runtime_args(command["args"] || command[:args]))
  end

  defp normalize_runtime_command(_), do: nil

  defp normalize_runtime_args(args) when is_list(args) do
    args
    |> Enum.map(&to_string/1)
    |> Enum.map(&truncate(&1, 300))
    |> Enum.take(40)
  end

  defp normalize_runtime_args(_), do: nil

  defp normalize_runtime_diff(diff) when is_map(diff) do
    files =
      (diff["files"] || diff[:files] || [])
      |> Enum.map(&normalize_runtime_file/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.take(@max_runtime_files)

    %{}
    |> maybe_put("git", runtime_bool(diff["git"] || diff[:git]))
    |> maybe_put(
      "filesChanged",
      normalize_runtime_int(diff["filesChanged"] || diff[:filesChanged]) || length(files)
    )
    |> maybe_put("additions", normalize_runtime_int(diff["additions"] || diff[:additions]) || 0)
    |> maybe_put("deletions", normalize_runtime_int(diff["deletions"] || diff[:deletions]) || 0)
    |> maybe_put("files", files)
    |> maybe_put("patch", runtime_patch(diff["patch"] || diff[:patch]))
    |> maybe_put("patchTruncated", runtime_bool(diff["patchTruncated"] || diff[:patchTruncated]))
  end

  defp normalize_runtime_diff(_), do: nil

  defp normalize_runtime_file(file) when is_map(file) do
    path = normalize_string(file["path"] || file[:path])
    name = normalize_string(file["name"] || file[:name]) || (path && Path.basename(path))

    if is_nil(path) and is_nil(name) do
      nil
    else
      %{}
      |> maybe_put("path", path || name)
      |> maybe_put("name", name || path)
      |> maybe_put("status", normalize_string(file["status"] || file[:status]) || "M")
      |> maybe_put("additions", normalize_runtime_int(file["additions"] || file[:additions]) || 0)
      |> maybe_put("deletions", normalize_runtime_int(file["deletions"] || file[:deletions]) || 0)
    end
  end

  defp normalize_runtime_file(_), do: nil

  defp normalize_runtime_controls(controls) when is_map(controls) do
    %{}
    |> maybe_put("canCancel", runtime_bool(controls["canCancel"] || controls[:canCancel]))
    |> maybe_put("canRevert", runtime_bool(controls["canRevert"] || controls[:canRevert]))
  end

  defp normalize_runtime_controls(_), do: nil

  defp normalize_team_metadata(opts) do
    %{}
    |> maybe_put("agentWorkerTeamMode", normalize_string(Keyword.get(opts, :team_mode)))
    |> maybe_put("agentWorkerTeamRunId", normalize_string(Keyword.get(opts, :team_run_id)))
    |> maybe_put("agentWorkerTeamWorker", normalize_string(Keyword.get(opts, :team_worker)))
    |> maybe_put(
      "agentWorkerTeamWorkers",
      normalize_team_workers(Keyword.get(opts, :team_workers))
    )
  end

  defp normalize_team_workers(values) when is_list(values) do
    values
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_team_workers(_), do: []

  defp normalize_runtime_int(value) when is_integer(value), do: value

  defp normalize_runtime_int(value) when is_float(value), do: round(value)

  defp normalize_runtime_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, _} -> number
      :error -> nil
    end
  end

  defp normalize_runtime_int(_), do: nil

  defp runtime_bool(value) when is_boolean(value), do: value
  defp runtime_bool(value) when is_binary(value), do: truthy?(value)
  defp runtime_bool(value) when is_integer(value), do: value != 0
  defp runtime_bool(_), do: nil

  defp runtime_patch(value) when is_binary(value), do: truncate(value, @max_runtime_patch_bytes)
  defp runtime_patch(_), do: nil

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
      |> maybe_put_subagent_type(kind, input)

    case patch_stats(tool, input) do
      {added, removed} when added > 0 or removed > 0 ->
        event |> Map.put("added", added) |> Map.put("removed", removed)

      _ ->
        event
    end
  end

  # The parent `Task` node carries the subagent flavor (e.g. "explore") so the
  # phone can render "🤖 Subagent · explore" and open its read-only view.
  defp maybe_put_subagent_type(event, "task", input) when is_map(input) do
    maybe_put(event, "subagentType", normalize_string(input["subagent_type"] || input["subagentType"]))
  end

  defp maybe_put_subagent_type(event, _kind, _input), do: event

  # Copy the structured shape fields from a tool event onto a progress node.
  defp copy_node_shape(node, event) do
    ["kind", "target", "added", "removed", "depth", "parentId", "subagentType"]
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
    path =
      input["file_path"] ||
        input["filePath"] ||
        input["target_file"] ||
        input["targetFile"] ||
        input["path"] ||
        input["notebook_path"] ||
        first_patch_path(input)

    parsed_patch_target = patch_target(input)

    cond do
      t in ["read", "read_file", "notebookread", "view", "cat", "open"] ->
        {"read", target_basename(path)}

      t in [
        "edit",
        "search_replace",
        "multiedit",
        "notebookedit",
        "str_replace",
        "str_replace_editor",
        "update",
        "apply_patch",
        "applypatch"
      ] ->
        {"edit", parsed_patch_target || target_basename(path)}

      t in ["write", "write_file", "create", "createfile", "new_file"] ->
        {"write", parsed_patch_target || target_basename(path)}

      t in [
        "bash",
        "shell",
        "exec",
        "run",
        "command",
        "terminal",
        "run_terminal_command"
      ] ->
        {"bash", short_target(input["command"] || input["cmd"])}

      t in [
        "grep",
        "search",
        "glob",
        "find",
        "ripgrep",
        "rg",
        "list_dir",
        "list_dir_tree"
      ] ->
        {"search",
         short_target(
           input["pattern"] || input["query"] || input["target_directory"] || path
         )}

      t in ["webfetch", "websearch", "fetch", "web_search", "web_fetch", "browse", "open_page"] ->
        {"web", short_target(input["url"] || input["query"] || input["domain"])}

      t in ["task", "agent", "dispatch_agent", "spawn_subagent", "get_command_or_subagent_output"] ->
        {"task", short_target(input["description"] || input["prompt"] || input["command"])}

      t in ["todowrite", "todo", "todo_write"] ->
        {"todo", nil}

      t in ["use_tool", "search_tool"] ->
        {"tool", short_target(input["tool_name"] || input["query"] || input["name"])}

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
    parsed_patch_stats = apply_patch_stats(input)

    cond do
      parsed_patch_stats != nil and
          t in ["edit", "search_replace", "multiedit", "update", "apply_patch", "applypatch"] ->
        parsed_patch_stats

      t in ["write", "write_file", "create", "createfile", "new_file"] ->
        {line_count(input["content"] || input["file_text"] || input["text"]), 0}

      t in [
        "edit",
        "search_replace",
        "notebookedit",
        "str_replace",
        "str_replace_editor",
        "update"
      ] ->
        {line_count(
           input["new_string"] || input["newString"] || input["new_str"] || input["new_source"]
         ),
         line_count(
           input["old_string"] || input["oldString"] || input["old_str"] || input["old_source"]
         )}

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
    |> case do
      "antigravity" -> "agy"
      other -> other
    end
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
