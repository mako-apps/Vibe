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

  alias Vibe.AI.LocalAgentWorker
  alias VibeWeb.Presence

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
        online_at: System.system_time(:second)
      })

    push(socket, "presence_state", Presence.list(socket))
    Logger.info("[AgentBridge] computer online user=#{socket.assigns.user_id}")
    {:noreply, socket}
  end

  # daemon → server: live progress for an in-flight task (raw stream-json line)
  @impl true
  def handle_in("progress", %{"provider" => provider, "chatId" => chat_id} = payload, socket) do
    case LocalAgentWorker.bridge_progress_event(provider, payload["line"] || "") do
      nil ->
        :ok

      event ->
        LocalAgentWorker.broadcast_activity(
          chat_id,
          agent_user_id_for(provider),
          event["label"] || "Working...",
          "running",
          event["tool"]
        )
    end

    {:noreply, socket}
  end

  # daemon → server: completed task (raw output + exit status)
  def handle_in("result", payload, socket) do
    provider = payload["provider"]
    chat_id = payload["chatId"]

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
            requester_user_id: requester_user_id
          )
        after
          LocalAgentWorker.stop_activity(chat_id, agent_user_id_for(provider))
        end
      end)
    end

    {:reply, :ok, socket}
  end

  # daemon → server: surface an error notice without a full result
  def handle_in("error", %{"provider" => provider, "chatId" => chat_id} = payload, socket) do
    message = payload["message"] || "The task could not be completed on your computer."
    LocalAgentWorker.post_bridge_notice(provider, chat_id, message, to_string(socket.assigns.user_id), payload["replyToId"])
    LocalAgentWorker.stop_activity(chat_id, agent_user_id_for(provider))
    {:reply, :ok, socket}
  end

  def handle_in("heartbeat", _payload, socket), do: {:reply, :ok, socket}
  def handle_in(_event, _payload, socket), do: {:noreply, socket}

  defp agent_user_id_for(provider) do
    case LocalAgentWorker.resolve_handle(provider) do
      nil -> LocalAgentWorker.agent_user_id()
      worker -> worker.agent_user_id
    end
  end
end
