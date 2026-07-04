defmodule VibeWeb.AgentBridgeChannel do
  @moduledoc """
  Channel for a user's paired computer. Topic is `bridge:<user_id>`.

  Flow:
    * The daemon joins and is tracked in Presence (so the server knows a computer
      is online and where to route `@claude` / `@codex`).
    * The server broadcasts `run_task` to this topic; Phoenix forwards it to the
      daemon automatically.
    * The daemon streams `progress` (raw stream-json lines) and a final `result`
      back; we reuse `Vibe.AI.LocalAgentWorker` to parse and post into the chat.
  """
  use VibeWeb, :channel
  require Logger

  alias Vibe.AgentBridge
  alias Vibe.AI.LocalAgentWorker
  alias VibeWeb.Presence

  # Keep only the most recent stream-json lines per in-flight task so a long run
  # can't grow the channel's memory without bound. The final `result` always
  # carries the complete output, so dropping the oldest progress lines is safe.
  @max_stream_lines 160

  @impl true
  def join("bridge:" <> topic_user_id, _payload, socket) do
    if topic_user_id == to_string(socket.assigns.user_id) do
      send(self(), :after_join)
      {:ok, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_info(:after_join, socket) do
    {:ok, _ref} =
      Presence.track(socket, to_string(socket.assigns.user_id), %{
        "online_at" => System.system_time(:second),
        "repositories" => []
      })

    push(socket, "presence_state", Presence.list(socket))
    Logger.info("[AgentBridge] computer online user=#{socket.assigns.user_id}")
    {:noreply, socket}
  end

  # daemon → server: connected device capabilities and allowed working trees
  @impl true
  def handle_in("status", payload, socket) do
    meta = AgentBridge.presence_meta(payload)
    key = to_string(socket.assigns.user_id)

    case Presence.update(socket, key, meta) do
      {:ok, _ref} ->
        :ok

      {:error, _reason} ->
        Presence.track(socket, key, meta)
    end

    {:reply, :ok, socket}
  end

  # daemon → server: live progress for an in-flight task (raw stream-json line).
  # We accumulate the lines for this chat and re-parse the buffer-so-far, then
  # broadcast a live `agent-stream` (partial text + inline tool/progress nodes)
  # so the reply renders as it is produced. The lightweight `agent-progress`
  # ping is kept for the typing indicator / backwards compatibility.
  #
  # Replies `:ok` (unlike most fire-and-forget events) because the bridge's
  # per-task frame log (vibe-bridge.js: pushProgressFrame/ackProgressFrame) only
  # prunes a frame once this ack lands — that's what lets a reconnect replay
  # exactly the frames lost in a drop instead of just the latest one.
  @impl true
  def handle_in("progress", %{"provider" => provider, "chatId" => chat_id} = payload, socket) do
    received_at_ms = System.system_time(:millisecond)
    parse_start_ms = System.monotonic_time(:millisecond)
    line = payload["line"] || ""
    streams = Map.get(socket.assigns, :streams, %{})

    state =
      Map.get(streams, chat_id, %{
        lines: [],
        stream_id: new_stream_id(chat_id),
        progress_count: 0,
        last_latency_log_at: 0
      })

    lines = Enum.take([line | state.lines], @max_stream_lines)
    accumulated = lines |> Enum.reverse() |> Enum.join("\n")
    task_id = payload["taskId"] || payload["task_id"] || Map.get(state, :task_id)
    progress_count = (Map.get(state, :progress_count) || 0) + 1

    source_message_id =
      payload["sourceMessageId"] ||
        payload["source_message_id"] ||
        payload["replyToId"] ||
        payload["reply_to_id"] ||
        Map.get(state, :source_message_id)

    state =
      Map.merge(state, %{
        lines: lines,
        task_id: task_id,
        source_message_id: source_message_id,
        repo_name: payload["repoName"] || payload["repo_name"] || Map.get(state, :repo_name),
        cwd: payload["cwd"] || Map.get(state, :cwd),
        work_mode: payload["workMode"] || payload["work_mode"] || Map.get(state, :work_mode),
        model: payload["model"] || Map.get(state, :model),
        progress_count: progress_count,
        bridge_sent_at_ms:
          payload["sentAtMs"] || payload["sent_at_ms"] || Map.get(state, :bridge_sent_at_ms),
        sequence: payload["sequence"] || Map.get(state, :sequence),
        team_mode: payload["teamMode"] || payload["team_mode"] || Map.get(state, :team_mode),
        team_run_id:
          payload["teamRunId"] || payload["team_run_id"] || Map.get(state, :team_run_id),
        team_worker:
          payload["teamWorker"] || payload["team_worker"] || Map.get(state, :team_worker),
        team_workers:
          payload["teamWorkers"] || payload["team_workers"] || Map.get(state, :team_workers)
      })

    # The live tool/execution feed now renders INSIDE the chat bubble (via the
    # agent-stream progress nodes), not as a tool-specific subtitle in the chat
    # header. We intentionally no longer broadcast `agent-progress` here.
    LocalAgentWorker.bridge_stream_update(provider, chat_id, accumulated, state.stream_id, %{
      task_id: state.task_id,
      source_message_id: state.source_message_id,
      reply_to_id: state.source_message_id,
      repo_name: state.repo_name,
      cwd: state.cwd,
      work_mode: state.work_mode,
      model: state.model,
      bridge_sent_at_ms: state.bridge_sent_at_ms,
      server_received_at_ms: received_at_ms,
      sequence: state.sequence,
      team_mode: state.team_mode,
      team_run_id: state.team_run_id,
      team_worker: state.team_worker,
      team_workers: state.team_workers
    })

    parse_ms = System.monotonic_time(:millisecond) - parse_start_ms
    bridge_lag_ms = bridge_lag_ms(state.bridge_sent_at_ms, received_at_ms)
    last_log_at = Map.get(state, :last_latency_log_at) || 0
    now_mono = System.monotonic_time(:millisecond)

    should_log =
      progress_count <= 3 or rem(progress_count, 10) == 0 or parse_ms > 250 or
        now_mono - last_log_at > 5_000

    state =
      if should_log do
        Logger.info(
          "[AgentBridge] progress latency provider=#{provider} chat=#{chat_id} task=#{inspect(task_id)} seq=#{inspect(state.sequence)} count=#{progress_count} bridgeLagMs=#{inspect(bridge_lag_ms)} parseMs=#{parse_ms} bytes=#{byte_size(accumulated)} lines=#{length(lines)}"
        )

        Map.put(state, :last_latency_log_at, now_mono)
      else
        state
      end

    {:reply, :ok, assign(socket, :streams, Map.put(streams, chat_id, state))}
  end

  # daemon → server: completed task (raw output + exit status)
  def handle_in("result", payload, socket) do
    provider = payload["provider"]
    chat_id = payload["chatId"]

    Logger.info(
      "[AgentBridge] result received user=#{socket.assigns.user_id} provider=#{inspect(provider)} chat=#{inspect(chat_id)} exit=#{inspect(payload["exitStatus"])} outputBytes=#{byte_size(payload["output"] || "")}"
    )

    if is_binary(provider) and is_binary(chat_id) do
      output = payload["output"] || ""
      exit_status = payload["exitStatus"] || 0
      duration_ms = payload["durationMs"] || 0
      reply_to_id = payload["replyToId"]
      requester_user_id = payload["requesterUserId"] || to_string(socket.assigns.user_id)

      Task.start(fn ->
        try do
          LocalAgentWorker.deliver_bridge_result(
            provider,
            chat_id,
            output,
            exit_status,
            duration_ms,
            reply_to_id: reply_to_id,
            requester_user_id: requester_user_id,
            runtime: payload["agentRuntime"] || payload["agent_runtime"],
            # End-to-end encrypted runtime blob. The server stores/relays this
            # verbatim and can never decrypt it (key lives only on the bridge +
            # phone). Never parse, normalize, or log its contents.
            runtime_enc: payload["agentRuntimeEnc"] || payload["agent_runtime_enc"],
            agent_actions_enc: payload["agentActionsEnc"] || payload["agent_actions_enc"],
            can_revert: payload["canRevert"] || payload["can_revert"] || false,
            team_mode: payload["teamMode"] || payload["team_mode"],
            team_run_id: payload["teamRunId"] || payload["team_run_id"],
            team_worker: payload["teamWorker"] || payload["team_worker"],
            team_workers: payload["teamWorkers"] || payload["team_workers"]
          )
        rescue
          err ->
            Logger.error(
              "[AgentBridge] deliver_bridge_result crashed chat=#{chat_id} provider=#{provider} error=#{Exception.message(err)}\n#{Exception.format(:error, err, __STACKTRACE__)}"
            )
        after
          LocalAgentWorker.stop_activity(chat_id, agent_user_id_for(provider))
        end
      end)
    end

    {:reply, :ok, clear_stream(socket, chat_id, provider)}
  end

  # daemon → server: the agent's local conversation history (Claude/Codex
  # session logs) in reply to a phone-issued `history_request`. We relay it to
  # the requesting chat so the Claude/Codex profile can render it.
  def handle_in("history_result", payload, socket) when is_map(payload) do
    chat_id = payload["chatId"] || payload["chat_id"]

    if is_binary(chat_id) and chat_id != "" do
      VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "agent-bridge-history", payload)
    else
      Logger.info(
        "[AgentBridge] history_result without chatId user=#{socket.assigns.user_id} requestId=#{inspect(payload["requestId"])}"
      )
    end

    {:reply, :ok, socket}
  end

  # daemon → server: the sealed full contents of a file the phone asked to open
  # (reply to a phone-issued `agent-bridge-file`). We relay it verbatim — the
  # `agentFileEnc` blob is opaque to us — back to the requesting chat.
  def handle_in("file_result", payload, socket) when is_map(payload) do
    chat_id = payload["chatId"] || payload["chat_id"]

    if is_binary(chat_id) and chat_id != "" do
      VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "agent-bridge-file", payload)
    else
      Logger.info(
        "[AgentBridge] file_result without chatId user=#{socket.assigns.user_id} requestId=#{inspect(payload["requestId"])}"
      )
    end

    {:reply, :ok, socket}
  end

  # daemon → server: a structured usage snapshot (Claude 5h/7-day limits + this
  # chat's last-run tokens) in reply to a phone-issued `agent-bridge-usage`. We
  # relay it to the requesting chat for the inline Usage panel.
  def handle_in("usage_result", payload, socket) when is_map(payload) do
    chat_id = payload["chatId"] || payload["chat_id"]

    if is_binary(chat_id) and chat_id != "" do
      VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "agent-bridge-usage", payload)
    else
      Logger.info(
        "[AgentBridge] usage_result without chatId user=#{socket.assigns.user_id} requestId=#{inspect(payload["requestId"])}"
      )
    end

    {:reply, :ok, socket}
  end

  # daemon → server: the agent (or the bridge's plan gate) needs the phone to
  # decide something — approve a plan, or answer a question. We relay it verbatim
  # to the requesting chat; the `askEnc` blob is opaque to us (sealed with the
  # pairing runtime key). The phone replies with `agent-bridge-ask-response`.
  def handle_in("ask_request", payload, socket) when is_map(payload) do
    chat_id = payload["chatId"] || payload["chat_id"]

    if is_binary(chat_id) and chat_id != "" do
      Logger.info(
        "[AgentBridge][ask] relay user=#{socket.assigns.user_id} chat=#{chat_id} " <>
          "requestId=#{inspect(payload["requestId"])} kind=#{inspect(payload["kind"])} " <>
          "sealed=#{Map.has_key?(payload, "askEnc")} → broadcast chat:#{chat_id}/agent-bridge-ask"
      )

      # Buffer before broadcasting so a phone that's mid-reconnect (and misses
      # the one-shot broadcast) gets it replayed on its next chat:<id> join.
      request_id = payload["requestId"] || payload["request_id"]

      if is_binary(request_id) do
        Vibe.AgentBridge.remember_pending_ask(chat_id, request_id, payload)
      end

      VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "agent-bridge-ask", payload)
    else
      Logger.info(
        "[AgentBridge][ask] DROPPED — no chatId user=#{socket.assigns.user_id} requestId=#{inspect(payload["requestId"])}"
      )
    end

    {:reply, :ok, socket}
  end

  # daemon → server: acknowledgement for a phone-issued task control action.
  def handle_in("control_result", payload, socket) do
    Logger.info(
      "[AgentBridge] control_result user=#{socket.assigns.user_id} payload=#{inspect(payload)}"
    )

    {:reply, :ok, socket}
  end

  # daemon → server: surface an error notice without a full result
  def handle_in("error", %{"provider" => provider, "chatId" => chat_id} = payload, socket) do
    Logger.info(
      "[AgentBridge] error received user=#{socket.assigns.user_id} provider=#{inspect(provider)} chat=#{inspect(chat_id)} message=#{inspect(payload["message"])}"
    )

    message = payload["message"] || "The task could not be completed on your computer."

    LocalAgentWorker.post_bridge_notice(
      provider,
      chat_id,
      message,
      to_string(socket.assigns.user_id),
      payload["replyToId"]
    )

    LocalAgentWorker.stop_activity(chat_id, agent_user_id_for(provider))
    {:reply, :ok, clear_stream(socket, chat_id, provider)}
  end

  def handle_in("heartbeat", _payload, socket), do: {:reply, :ok, socket}
  def handle_in(_event, _payload, socket), do: {:noreply, socket}

  defp bridge_lag_ms(value, received_at_ms) when is_integer(value), do: received_at_ms - value

  defp bridge_lag_ms(value, received_at_ms) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> received_at_ms - int
      _ -> nil
    end
  end

  defp bridge_lag_ms(_, _), do: nil

  defp new_stream_id(chat_id) do
    "stream-" <> chat_id <> "-" <> Integer.to_string(System.system_time(:millisecond))
  end

  # Finish + drop the live stream for a chat once the task ends.
  defp clear_stream(socket, chat_id, provider) when is_binary(chat_id) do
    streams = Map.get(socket.assigns, :streams, %{})

    case Map.pop(streams, chat_id) do
      {nil, _streams} ->
        socket

      {state, rest} ->
        if is_binary(provider),
          do: LocalAgentWorker.finish_stream(provider, chat_id, state.stream_id)

        assign(socket, :streams, rest)
    end
  end

  defp clear_stream(socket, _chat_id, _provider), do: socket

  defp agent_user_id_for(provider) do
    case LocalAgentWorker.resolve_handle(provider) do
      nil -> LocalAgentWorker.agent_user_id()
      worker -> worker.agent_user_id
    end
  end
end
