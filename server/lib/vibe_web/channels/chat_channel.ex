defmodule VibeWeb.ChatChannel do
  use VibeWeb, :channel
  alias Vibe.AgentBridge
  alias Vibe.Agents
  alias Vibe.Chat
  alias Vibe.Chat.AgentMessageCrypto
  alias Vibe.Notifications
  alias Vibe.AI.GroupAgent
  alias Vibe.AI.LocalAgentWorker
  alias Vibe.AI.StandaloneAgent
  require Logger

  # Sealed agent image blobs (arte1). They ride the inbound message only to reach the
  # bridge dispatch; they are stripped from the broadcast + persisted row so devices
  # never ingest a 270KB+ metadata blob. The bridge reads them off the untouched data.
  @inline_attachment_keys ~w(agentBridgeAttachmentsEnc agent_bridge_attachments_enc attachmentsEnc)

  @impl true
  def join("chat:" <> chat_id, _payload, socket) do
    user_id = socket.assigns.user_id
    # Verify access and cache room type + role in socket assigns
    # so we skip DB queries on every message send.
    case Chat.get_user_role(chat_id, user_id) do
      nil ->
        {:error, %{reason: "unauthorized"}}

      role ->
        room_type = Chat.get_room_type(chat_id) || "dm"
        socket = assign(socket, :room_type, room_type)
        socket = assign(socket, :user_role, role)
        # Replay any ask the phone missed while it was offline/reconnecting.
        send(self(), {:replay_pending_ask, chat_id})
        {:ok, socket}
    end
  end

  @impl true
  def handle_info({:replay_pending_ask, chat_id}, socket) do
    case AgentBridge.pending_ask(chat_id) do
      payload when is_map(payload) ->
        Logger.info(
          "[AgentBridge][ask] replay-on-join chat=#{chat_id} " <>
            "requestId=#{inspect(payload["requestId"])} → push agent-bridge-ask"
        )

        push(socket, "agent-bridge-ask", payload)

      _ ->
        :noop
    end

    {:noreply, socket}
  end

  # Catch-all: keep parity with Phoenix's default (no-op) now that this channel
  # exports handle_info/2 — otherwise any other process message would crash it.
  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_in("message", payload, socket) do
    "chat:" <> chat_id = socket.topic
    user_id = socket.assigns.user_id

    # Check send permission using cached socket assigns (no DB hit)
    can_send =
      case socket.assigns.room_type do
        "channel" -> socket.assigns.user_role in ["owner", "admin"]
        # Already verified as participant on join
        _ -> true
      end

    if not can_send do
      {:reply, {:error, %{reason: "not_allowed", message: "You cannot send messages here"}},
       socket}
    else
      standalone_agent =
        case socket.assigns.room_type do
          "dm" ->
            chat_id
            |> Chat.get_participant_ids()
            |> Enum.reject(&(&1 == user_id))
            |> Enum.find_value(&Agents.get_agent_by_shadow_user/1)

          _ ->
            nil
        end

      if standalone_agent && !Agents.incoming_chat_enabled?(standalone_agent) do
        {:reply,
         {:error,
          %{reason: "agent_chat_disabled", message: "Incoming chat is disabled for this agent"}},
         socket}
      else
        data = deobfuscate(payload)
        # The sealed image blobs ride `data` only to reach the bridge dispatch below
        # (which reads the untouched `data`). They must NOT ride the chat broadcast or
        # the persisted row — a 270KB+ metadata blob echoed to every device is slow to
        # parse and bloats storage. Strip them from everything except the dispatch.
        broadcast_payload = strip_inline_agent_attachments(enforce_sender_identity(data, user_id))
        message_metadata = message_metadata_for_persistence(data, standalone_agent)

        message_attrs = %{
          chat_id: chat_id,
          from_id: user_id,
          id: data["id"],
          encrypted_content: data["encryptedContent"],
          type: data["type"] || "text",
          timestamp: data["timestamp"] || :os.system_time(:millisecond),
          reply_to_id: data["replyToId"],
          media_url: data["mediaUrl"],
          metadata: message_metadata
        }

        # BROADCAST IMMEDIATELY for instant message delivery
        broadcast!(socket, "message", broadcast_payload)

        # Mirror a lightweight ping to the sender's OWN other devices. The chat-topic
        # broadcast above only reaches devices that currently have THIS chat open, so
        # a message typed on the phone never reached the same user's laptop sitting on
        # the chat list. This `new_message` on the sender's user topic lets those other
        # devices refresh in real time (no push — it's the sender's own device).
        VibeWeb.Endpoint.broadcast!("user:#{user_id}", "new_message", %{
          chat_id: chat_id,
          from_id: user_id,
          message_id: data["id"],
          timestamp: data["timestamp"],
          self_echo: true
        })

        # Check for @vibe agent mention and dispatch to group agent.
        # Run async: resolution does several synchronous DB reads (room type,
        # participant ids ×2, shadow-agent lookup, local-worker + attachment
        # context) that previously blocked the sender's "sent" ack by ~2s even
        # for a plain no-agent DM. It's pure fire-and-forget fan-out (spawns
        # workers / logs) with an unused return value, so defer it past the reply.
        Task.start(fn -> maybe_dispatch_agent(chat_id, data, user_id) end)

        # Persist to database asynchronously (don't block message delivery)
        Task.start(fn ->
          case Chat.add_message(message_attrs, acting_user_id: user_id) do
            {:ok, _msg} ->
              # Batch-fetch all participants with settings in ONE query (no N+1)
              participants = Chat.get_all_participant_settings(chat_id)

              Logger.info(
                "[ChatChannel] message persisted chat_id=#{chat_id} sender=#{user_id} participants=#{length(participants)} message_id=#{data["id"]}"
              )

              Enum.each(participants, fn p ->
                if p.user_id != user_id do
                  if p.deleted, do: Chat.restore_if_deleted(chat_id, p.user_id)

                  VibeWeb.Endpoint.broadcast!("user:#{p.user_id}", "new_message", %{
                    chat_id: chat_id,
                    from_id: user_id,
                    message_id: data["id"],
                    timestamp: data["timestamp"],
                    muted: p.muted || false
                  })

                  if p.muted do
                    Logger.info(
                      "[ChatChannel] push skipped (muted chat) recipient=#{p.user_id} chat_id=#{chat_id} message_id=#{data["id"]}"
                    )
                  else
                    push_body =
                      case data["pushPreview"] || data["push_preview"] || data["textPreview"] ||
                             data["text_preview"] do
                        value when is_binary(value) and value != "" -> value
                        _ -> nil
                      end

                    _ =
                      Notifications.send_message_push(p.user_id, %{
                        "chat_id" => chat_id,
                        "message_id" => data["id"],
                        "from_id" => user_id,
                        "type" => data["type"],
                        "body" => push_body,
                        "media_url" => data["mediaUrl"] || data["media_url"]
                      })
                  end
                end
              end)

            {:error, changeset} ->
              # Log persistence failure but don't crash
              Logger.error("Message persistence failed: #{inspect(changeset)}")
          end
        end)

        # Reply immediately - don't wait for DB
        {:reply, :ok, socket}
      end
    end
  end

  @impl true
  def handle_in("agent-bridge-control", payload, socket) when is_map(payload) do
    "chat:" <> chat_id = socket.topic
    user_id = socket.assigns.user_id
    action = normalize_control_action(payload["action"] || payload["type"])
    provider = normalize_bridge_provider(payload["provider"] || payload["agentBridgeProvider"])

    task_id =
      normalize_bridge_string(payload["taskId"] || payload["agentTaskId"] || payload["messageId"])

    cond do
      is_nil(action) ->
        {:reply, {:error, %{reason: "invalid_action"}}, socket}

      is_nil(provider) ->
        {:reply, {:error, %{reason: "invalid_provider"}}, socket}

      true ->
        control_payload =
          %{
            "action" => action,
            "provider" => provider,
            "chatId" => chat_id,
            "requesterUserId" => user_id
          }
          |> put_optional_string("taskId", task_id)

        case AgentBridge.dispatch_control(user_id, control_payload) do
          :ok -> {:reply, :ok, socket}
          {:error, :offline} -> {:reply, {:error, %{reason: "offline"}}, socket}
        end
    end
  end

  @impl true
  def handle_in("agent-bridge-history", payload, socket) when is_map(payload) do
    "chat:" <> chat_id = socket.topic
    user_id = socket.assigns.user_id
    provider = normalize_bridge_provider(payload["provider"] || payload["agentBridgeProvider"])

    if is_nil(provider) do
      {:reply, {:error, %{reason: "invalid_provider"}}, socket}
    else
      request_payload =
        %{
          "requestId" => normalize_bridge_string(payload["requestId"]) || Ecto.UUID.generate(),
          "provider" => provider,
          "chatId" => chat_id,
          "requesterUserId" => user_id,
          "mode" => normalize_bridge_string(payload["mode"]) || "list"
        }
        |> put_optional_string("sessionId", normalize_bridge_string(payload["sessionId"]))
        |> put_optional_string(
          "before",
          normalize_bridge_string(payload["before"] || payload["beforeCursor"])
        )
        |> put_optional_positive_integer("limit", payload["limit"])

      case AgentBridge.dispatch_history(user_id, request_payload) do
        :ok -> {:reply, {:ok, %{"requestId" => request_payload["requestId"]}}, socket}
        {:error, :offline} -> {:reply, {:error, %{reason: "offline"}}, socket}
      end
    end
  end

  # phone → server: open the full contents of a file the agent touched. We relay
  # it to the user's bridge, which reads it (path-guarded), seals it with the
  # runtime key, and replies with `file_result` (relayed back as
  # `agent-bridge-file`). The server never sees the file in the clear.
  def handle_in("agent-bridge-file", payload, socket) when is_map(payload) do
    "chat:" <> chat_id = socket.topic
    user_id = socket.assigns.user_id
    provider = normalize_bridge_provider(payload["provider"] || payload["agentBridgeProvider"])
    file_path = normalize_bridge_string(payload["path"] || payload["file"])

    cond do
      is_nil(provider) ->
        {:reply, {:error, %{reason: "invalid_provider"}}, socket}

      is_nil(file_path) ->
        {:reply, {:error, %{reason: "invalid_path"}}, socket}

      true ->
        request_payload = %{
          "requestId" => normalize_bridge_string(payload["requestId"]) || Ecto.UUID.generate(),
          "provider" => provider,
          "chatId" => chat_id,
          "requesterUserId" => user_id,
          "path" => file_path
        }

        case AgentBridge.dispatch_file(user_id, request_payload) do
          :ok -> {:reply, {:ok, %{"requestId" => request_payload["requestId"]}}, socket}
          {:error, :offline} -> {:reply, {:error, %{reason: "offline"}}, socket}
        end
    end
  end

  # phone → server: fetch the connected bridge's live usage snapshot (Claude
  # subscription 5h/7-day limits + this chat's last-run tokens) for the inline
  # Usage panel. The daemon replies with `usage_result`, relayed back as
  # `agent-bridge-usage`.
  def handle_in("agent-bridge-usage", payload, socket) when is_map(payload) do
    "chat:" <> chat_id = socket.topic
    user_id = socket.assigns.user_id
    provider = normalize_bridge_provider(payload["provider"] || payload["agentBridgeProvider"])

    if is_nil(provider) do
      {:reply, {:error, %{reason: "invalid_provider"}}, socket}
    else
      request_payload = %{
        "requestId" => normalize_bridge_string(payload["requestId"]) || Ecto.UUID.generate(),
        "provider" => provider,
        "chatId" => chat_id,
        "requesterUserId" => user_id
      }

      case AgentBridge.dispatch_usage(user_id, request_payload) do
        :ok -> {:reply, {:ok, %{"requestId" => request_payload["requestId"]}}, socket}
        {:error, :offline} -> {:reply, {:error, %{reason: "offline"}}, socket}
      end
    end
  end

  # phone → server: the user's answer to a bridge-issued `ask_request` (plan
  # approval or a mid-run question). We relay it to the user's bridge, which
  # resolves the pending ask. The `answerEnc` blob is sealed with the runtime key
  # (the server stays blind). `decision` ∈ "approve" | "reject" | "answer".
  def handle_in("agent-bridge-ask-response", payload, socket) when is_map(payload) do
    "chat:" <> chat_id = socket.topic
    user_id = socket.assigns.user_id
    request_id = normalize_bridge_string(payload["requestId"] || payload["request_id"])

    decision =
      case normalize_bridge_string(payload["decision"] || payload["action"]) do
        d when d in ["approve", "reject", "answer"] -> d
        _ -> "answer"
      end

    if is_nil(request_id) do
      {:reply, {:error, %{reason: "invalid_request_id"}}, socket}
    else
      response_payload =
        %{
          "requestId" => request_id,
          "chatId" => chat_id,
          "requesterUserId" => user_id,
          "decision" => decision
        }
        |> put_optional_string("answerEnc", normalize_bridge_string(payload["answerEnc"]))
        |> put_optional_string(
          "provider",
          normalize_bridge_provider(payload["provider"] || payload["agentBridgeProvider"])
        )

      # The phone answered — drop the buffered ask so it isn't replayed on rejoin.
      AgentBridge.clear_pending_ask(chat_id, request_id)

      case AgentBridge.dispatch_ask_response(user_id, response_payload) do
        :ok -> {:reply, :ok, socket}
        {:error, :offline} -> {:reply, {:error, %{reason: "offline"}}, socket}
      end
    end
  end

  @impl true
  def handle_in("typing", payload, socket) do
    broadcast_from!(socket, "typing", payload)
    {:noreply, socket}
  end

  @impl true
  def handle_in("recording", payload, socket) do
    broadcast_from!(socket, "recording", payload)
    {:noreply, socket}
  end

  @impl true
  def handle_in("stop-recording", payload, socket) do
    broadcast_from!(socket, "stop-recording", payload)
    {:noreply, socket}
  end

  @impl true
  def handle_in("stop-typing", payload, socket) do
    broadcast_from!(socket, "stop-typing", payload)
    {:noreply, socket}
  end

  @impl true
  def handle_in("read-receipt", %{"messageId" => msg_id} = payload, socket) do
    Vibe.Chat.mark_read(msg_id, socket.assigns.user_id)
    broadcast_from!(socket, "message-read", payload)
    {:noreply, socket}
  end

  @impl true
  def handle_in("delivery-receipt", %{"messageId" => msg_id} = payload, socket) do
    Vibe.Chat.mark_delivered(msg_id, socket.assigns.user_id)
    broadcast_from!(socket, "message-delivered", payload)
    {:noreply, socket}
  end

  @impl true
  def handle_in("delete-message", %{"messageId" => msg_id} = payload, socket) do
    "chat:" <> chat_id = socket.topic
    user_id = socket.assigns.user_id

    for_everyone =
      case Map.get(payload, "forEveryone", true) do
        v when v in [true, "true", "1", 1] -> true
        _ -> false
      end

    case Vibe.Chat.delete_message(chat_id, msg_id, user_id, for_everyone) do
      {:ok, _message} ->
        broadcast!(socket, "message-deleted", %{
          messageId: msg_id,
          deletedBy: user_id,
          forEveryone: for_everyone
        })

        {:reply, :ok, socket}

      {:error, :invalid_id} ->
        {:reply, {:error, %{reason: "invalid_id"}}, socket}

      {:error, :forbidden} ->
        {:reply, {:error, %{reason: "forbidden"}}, socket}

      {:error, :not_found} ->
        {:reply, {:error, %{reason: "not_found"}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  @impl true
  def handle_in(
        "edit-message",
        %{"messageId" => msg_id, "encryptedContent" => encrypted_content} = payload,
        socket
      ) do
    "chat:" <> chat_id = socket.topic
    user_id = socket.assigns.user_id
    edited_at = Map.get(payload, "editedAt")

    case Vibe.Chat.edit_message(chat_id, msg_id, user_id, encrypted_content, edited_at) do
      {:ok, _message} ->
        broadcast!(socket, "message-edited", %{
          messageId: msg_id,
          encryptedContent: encrypted_content,
          editedAt: edited_at || :os.system_time(:millisecond),
          editedBy: user_id
        })

        {:reply, :ok, socket}

      {:error, :invalid_id} ->
        {:reply, {:error, %{reason: "invalid_id"}}, socket}

      {:error, :forbidden} ->
        {:reply, {:error, %{reason: "forbidden"}}, socket}

      {:error, :not_found} ->
        {:reply, {:error, %{reason: "not_found"}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  # ── Agent Dispatch ──

  defp maybe_dispatch_agent(chat_id, data, user_id) do
    Logger.info(
      "[ChatChannel] maybe_dispatch_agent chat_id=#{chat_id} keys=#{inspect(Map.keys(data))} agentMention=#{inspect(data["agentMention"])} mentionedAgentId=#{inspect(data["mentionedAgentId"] || data["mentioned_agent_id"])}"
    )

    agent_mention = data["agentMention"] || false
    mentioned_agent_id = data["mentionedAgentId"] || data["mentioned_agent_id"]
    room_type = Chat.get_room_type(chat_id) || "dm"
    participant_ids = Chat.get_participant_ids(chat_id)

    reserved_workers = reserved_workers_from_text(data)

    mentioned_agent_username =
      data["mentionedAgentUsername"] || data["mentioned_agent_username"] ||
        case reserved_workers do
          [%{handle: handle} | _] -> handle
          _ -> nil
        end

    agent_text = data["agentText"]
    reply_to_id = data["replyToId"] || data["reply_to_id"]

    reply_message =
      case reply_to_id do
        value when is_binary(value) and value != "" -> Chat.get_message(chat_id, value, user_id)
        _ -> nil
      end

    standalone_agent =
      cond do
        is_binary(mentioned_agent_id) and String.trim(mentioned_agent_id) != "" ->
          Agents.get_agent(mentioned_agent_id)

        is_binary(mentioned_agent_username) and String.trim(mentioned_agent_username) != "" ->
          Agents.get_agent_by_username(mentioned_agent_username)

        match?(%{from_id: _}, reply_message) ->
          Agents.get_agent_by_shadow_user(reply_message.from_id)

        true ->
          nil
      end

    local_worker =
      if standalone_agent do
        nil
      else
        LocalAgentWorker.resolve_handle(mentioned_agent_username) ||
          LocalAgentWorker.resolve_from_message(reply_message) ||
          local_worker_for_dm(chat_id, user_id)
      end

    standalone_agent =
      standalone_agent ||
        case room_type do
          "dm" ->
            chat_id
            |> Chat.get_participant_ids()
            |> Enum.reject(&(&1 == user_id))
            |> Enum.find_value(&Agents.get_agent_by_shadow_user/1)

          _ ->
            nil
        end

    group_trigger? =
      agent_mention ||
        case reply_message do
          %{from_id: from_id} ->
            normalized_from = from_id |> to_string() |> String.downcase() |> String.trim()
            normalized_agent = GroupAgent.agent_user_id() |> String.downcase() |> String.trim()
            normalized_from == normalized_agent

          _ ->
            false
        end

    dispatch_text =
      case normalize_dispatch_text(agent_text, data) do
        nil -> nil
        value -> value
      end

    team_trigger? = LocalAgentWorker.team_trigger?(dispatch_text)

    team_dispatch_text =
      if team_trigger?,
        do: LocalAgentWorker.strip_team_trigger(dispatch_text),
        else: dispatch_text

    team_workers =
      if room_type != "dm" and team_trigger? do
        LocalAgentWorker.team_workers_for_participants(participant_ids)
      else
        []
      end

    attachment_context = extract_agent_attachment_context(chat_id, data, user_id)

    Logger.info(
      "[ChatChannel] dispatch_resolve chat_id=#{chat_id} room_type=#{room_type} reserved=#{length(reserved_workers)} team=#{team_trigger?} team_workers=#{Enum.map_join(team_workers, ",", & &1.handle)} standalone=#{not is_nil(standalone_agent)} local_worker=#{if local_worker, do: local_worker.handle, else: "nil"} dispatch_text?=#{is_binary(dispatch_text)} agent_text?=#{is_binary(agent_text) and String.trim(to_string(agent_text)) != ""} mentioned_username=#{inspect(mentioned_agent_username)} participants=#{inspect(participant_ids)}"
    )

    cond do
      room_type != "dm" and team_trigger? and length(team_workers) > 1 and
          is_binary(team_dispatch_text) ->
        spawn_team_worker_dispatches(
          chat_id,
          team_workers,
          team_dispatch_text,
          data,
          user_id
        )

      room_type != "dm" and is_nil(standalone_agent) and length(reserved_workers) > 1 and
          is_binary(dispatch_text) ->
        reserved_workers
        |> Enum.with_index()
        |> Enum.each(fn {worker, index} ->
          spawn_local_worker_dispatch(
            chat_id,
            worker,
            dispatch_text,
            data,
            "reserved_worker_group",
            user_id,
            skip_rate_limit: index > 0
          )
        end)

      local_worker && is_binary(dispatch_text) ->
        trigger_type =
          cond do
            is_binary(mentioned_agent_username) -> "mention"
            reply_message -> "reply"
            true -> "reserved_worker"
          end

        spawn_local_worker_dispatch(
          chat_id,
          local_worker,
          dispatch_text,
          data,
          trigger_type,
          user_id
        )

      standalone_agent && is_binary(dispatch_text) ->
        trigger_type =
          cond do
            is_binary(mentioned_agent_id) or is_binary(mentioned_agent_username) -> "mention"
            reply_message -> "reply"
            true -> "dm"
          end

        spawn_standalone_dispatch(
          chat_id,
          standalone_agent,
          dispatch_text,
          data,
          attachment_context,
          trigger_type,
          user_id
        )

      group_trigger? && is_binary(dispatch_text) ->
        trigger_type = if agent_mention, do: "mention", else: "reply"

        metadata = %{
          "image_urls" => attachment_context.image_urls,
          "document_urls" => attachment_context.document_urls,
          "audio_urls" => attachment_context.audio_urls,
          "reply_to_id" => data["id"],
          "message_id" => data["id"],
          "trigger_type" => trigger_type
        }

        spawn_group_dispatch(chat_id, dispatch_text, user_id, metadata)

      true ->
        Logger.info("[ChatChannel] No agent mention detected for chat #{chat_id}")
    end
  end

  defp spawn_team_worker_dispatches(chat_id, workers, dispatch_text, data, requester_user_id) do
    team_run_id = data["id"] || Ecto.UUID.generate()
    bridge_metadata = bridge_task_metadata(data)

    first_worker =
      LocalAgentWorker.register_bridge_team_run(
        chat_id,
        team_run_id,
        workers,
        dispatch_text,
        requester_user_id,
        data["id"],
        bridge_metadata
      )

    case first_worker do
      nil ->
        :ok

      worker ->
        spawn_local_worker_dispatch(
          chat_id,
          worker,
          dispatch_text,
          data,
          "reserved_worker_team",
          requester_user_id,
          bridge_metadata: bridge_metadata,
          note_user_turn: false,
          note_team_user_turn: true,
          team_run_id: team_run_id,
          team_workers: workers
        )
    end
  end

  defp spawn_local_worker_dispatch(
         chat_id,
         worker,
         dispatch_text,
         data,
         _trigger_type,
         requester_user_id,
         opts \\ []
       ) do
    skip_rate_limit = Keyword.get(opts, :skip_rate_limit, false)
    note_user_turn? = Keyword.get(opts, :note_user_turn, true)
    note_team_user_turn? = Keyword.get(opts, :note_team_user_turn, false)
    team_run_id = Keyword.get(opts, :team_run_id)
    team_workers = Keyword.get(opts, :team_workers, [])
    bridge_metadata = Keyword.get(opts, :bridge_metadata) || bridge_task_metadata(data)

    cond do
      not LocalAgentWorker.user_allowed?(requester_user_id) ->
        maybe_clear_team_run(chat_id, team_run_id)

        Logger.warning(
          "[ChatChannel] local worker blocked: user=#{requester_user_id} not in VIBE_AGENT_WORKER_ALLOWED_USERS"
        )

        :ok

      not skip_rate_limit and not LocalAgentWorker.allow_request?(requester_user_id) ->
        maybe_clear_team_run(chat_id, team_run_id)

        LocalAgentWorker.post_notice(
          worker,
          chat_id,
          "You're sending @#{worker.handle} tasks too quickly. Please wait a few seconds and try again.",
          requester_user_id,
          data["id"]
        )

      # Preferred path: run on the user's OWN paired computer (their subscription).
      AgentBridge.online?(requester_user_id) ->
        broadcast_agent_activity(
          chat_id,
          worker.agent_user_id,
          "#{worker.label} working...",
          "running"
        )

        bridge_prompt =
          if is_binary(team_run_id) do
            LocalAgentWorker.build_team_bridge_prompt(
              chat_id,
              worker,
              dispatch_text,
              requester_user_id,
              team_workers,
              team_run_id
            )
          else
            LocalAgentWorker.build_bridge_prompt(
              chat_id,
              worker,
              dispatch_text,
              requester_user_id
            )
          end

        task_payload =
          %{
            "provider" => worker.handle,
            "chatId" => chat_id,
            "taskId" => data["id"] || Ecto.UUID.generate(),
            "prompt" => bridge_prompt,
            "replyToId" => data["id"],
            "requesterUserId" => requester_user_id
          }
          |> Map.merge(local_worker_team_metadata(worker, team_run_id, team_workers))
          |> Map.merge(bridge_metadata)

        case AgentBridge.dispatch_task(requester_user_id, task_payload) do
          :ok ->
            # Record the human's prompt in the shared group thread (no-op in DMs)
            # only once we know it was actually dispatched.
            cond do
              note_team_user_turn? ->
                LocalAgentWorker.note_bridge_team_user_turn(
                  chat_id,
                  team_workers,
                  dispatch_text,
                  requester_user_id,
                  team_run_id
                )

              note_user_turn? ->
                LocalAgentWorker.note_bridge_user_turn(
                  chat_id,
                  worker,
                  dispatch_text,
                  requester_user_id
                )

              true ->
                :ok
            end

            Logger.info(
              "[ChatChannel] dispatched @#{worker.handle} to bridge user=#{requester_user_id} chat=#{chat_id}"
            )

          {:error, :offline} ->
            maybe_clear_team_run(chat_id, team_run_id)

            # Raced with a disconnect — re-lock to the connect prompt.
            stop_agent_activity(chat_id, worker.agent_user_id)

            LocalAgentWorker.post_notice(
              worker,
              chat_id,
              "Your computer just went offline. Reconnect it to run @#{worker.handle} tasks.",
              requester_user_id,
              data["id"]
            )
        end

      # Dev fallback: run on the server itself (VIBE_LOCAL_AGENT_WORKERS=1).
      LocalAgentWorker.enabled?() ->
        run = fn ->
          broadcast_agent_activity(
            chat_id,
            worker.agent_user_id,
            "#{worker.label} working...",
            "running"
          )

          try do
            case LocalAgentWorker.handle_chat_message(
                   worker,
                   chat_id,
                   dispatch_text,
                   reply_to_id: data["id"],
                   requester_user_id: requester_user_id,
                   bridge_metadata: bridge_metadata,
                   progress_callback: fn event ->
                     broadcast_agent_activity(
                       chat_id,
                       worker.agent_user_id,
                       Map.get(event, "label") || "#{worker.label} working...",
                       "running",
                       Map.get(event, "tool")
                     )
                   end
                 ) do
              {:ok, _response} ->
                Logger.info(
                  "[ChatChannel] Local worker responded chat_id=#{chat_id} provider=#{worker.handle}"
                )

              {:error, reason} ->
                Logger.error(
                  "[ChatChannel] Local worker dispatch failed chat_id=#{chat_id} provider=#{worker.handle} reason=#{inspect(reason)}"
                )
            end
          after
            stop_agent_activity(chat_id, worker.agent_user_id)
          end
        end

        case Task.Supervisor.start_child(Vibe.AI.WorkerTaskSupervisor, run) do
          {:error, :max_children} ->
            LocalAgentWorker.post_notice(
              worker,
              chat_id,
              "#{worker.label} is busy with other tasks right now. Please try again in a moment.",
              requester_user_id,
              data["id"]
            )

          _ ->
            :ok
        end

      # No computer connected: tell the user how to connect.
      true ->
        LocalAgentWorker.post_notice(
          worker,
          chat_id,
          "Connect your computer to run @#{worker.handle}. Open #{worker.label} in Vibe and tap Connect to pair this chat with your machine.",
          requester_user_id,
          data["id"]
        )
    end
  end

  defp maybe_clear_team_run(_chat_id, nil), do: :ok

  defp maybe_clear_team_run(chat_id, team_run_id),
    do: LocalAgentWorker.clear_bridge_team_run(chat_id, team_run_id)

  defp local_worker_team_metadata(_worker, nil, _team_workers), do: %{}

  defp local_worker_team_metadata(worker, team_run_id, team_workers) do
    %{
      "teamMode" => "group_team",
      "teamRunId" => team_run_id,
      "teamWorker" => worker.handle,
      "teamWorkers" => Enum.map(team_workers, & &1.handle)
    }
  end

  defp spawn_standalone_dispatch(
         chat_id,
         agent,
         dispatch_text,
         data,
         attachment_context,
         _trigger_type,
         requester_user_id
       ) do
    Task.start(fn ->
      broadcast_agent_activity(chat_id, agent.agent_user_id, "Thinking...", "running")

      try do
        attachments =
          attachment_context_to_attachments(attachment_context)

        case StandaloneAgent.handle_chat_message(
               agent,
               chat_id,
               dispatch_text,
               attachments: attachments,
               reply_to_id: data["id"],
               requester_user_id: requester_user_id
             ) do
          {:ok, _response} ->
            Logger.info(
              "[ChatChannel] Standalone agent responded chat_id=#{chat_id} agent_id=#{agent.id}"
            )

          {:error, reason} ->
            Logger.error(
              "[ChatChannel] Standalone agent dispatch failed chat_id=#{chat_id} agent_id=#{agent.id} reason=#{inspect(reason)}"
            )
        end
      after
        stop_agent_activity(chat_id, agent.agent_user_id)
      end
    end)
  end

  defp spawn_group_dispatch(chat_id, dispatch_text, user_id, metadata) do
    Task.start(fn ->
      broadcast_agent_activity(chat_id, GroupAgent.agent_user_id(), "Thinking...", "running")

      try do
        case GroupAgent.handle_mention(chat_id, dispatch_text, user_id, metadata) do
          {:ok, _response} ->
            Logger.info("[ChatChannel] Agent responded in chat #{chat_id}")

          {:error, :no_agent} ->
            Logger.debug("[ChatChannel] No agent configured for chat #{chat_id}")

          {:error, reason} ->
            Logger.error(
              "[ChatChannel] Agent dispatch failed for chat #{chat_id}: #{inspect(reason)}"
            )
        end
      after
        stop_agent_activity(chat_id, GroupAgent.agent_user_id())
      end
    end)
  end

  defp normalize_dispatch_text(agent_text, data) do
    value =
      cond do
        is_binary(agent_text) and String.trim(agent_text) != "" ->
          agent_text

        true ->
          data["pushPreview"] || data["textPreview"] || data["text"] || data["body"]
      end

    case value do
      text when is_binary(text) ->
        trimmed = String.trim(text)
        if trimmed == "", do: nil, else: trimmed

      _ ->
        nil
    end
  end

  defp reserved_workers_from_text(data) do
    text = data["pushPreview"] || data["textPreview"] || data["text"] || data["body"]
    LocalAgentWorker.extract_reserved_mentions(text)
  end

  defp bridge_task_metadata(data) do
    metadata =
      case data["metadata"] || data["meta"] do
        value when is_map(value) -> value
        _ -> %{}
      end

    %{}
    |> put_optional_string(
      "cwd",
      metadata["agentBridgeCwd"] || metadata["agent_bridge_cwd"] || data["agentBridgeCwd"]
    )
    |> put_optional_string(
      "repoId",
      metadata["agentBridgeRepoId"] || metadata["agent_bridge_repo_id"] ||
        data["agentBridgeRepoId"]
    )
    |> put_optional_string(
      "repoName",
      metadata["agentBridgeRepoName"] || metadata["agent_bridge_repo_name"] ||
        data["agentBridgeRepoName"]
    )
    |> put_optional_string(
      "workMode",
      metadata["agentBridgeWorkMode"] || metadata["agent_bridge_work_mode"] ||
        data["agentBridgeWorkMode"]
    )
    |> put_optional_string(
      "model",
      metadata["agentBridgeModel"] || metadata["agent_bridge_model"] || data["agentBridgeModel"]
    )
    |> put_optional_string(
      "intelligence",
      metadata["agentBridgeIntelligence"] || metadata["agent_bridge_intelligence"] ||
        data["agentBridgeIntelligence"]
    )
    |> put_optional_string(
      "speed",
      metadata["agentBridgeSpeed"] || metadata["agent_bridge_speed"] || data["agentBridgeSpeed"]
    )
    |> put_optional_string(
      "reasoningEffort",
      metadata["agentBridgeReasoningEffort"] || metadata["agent_bridge_reasoning_effort"] ||
        data["agentBridgeReasoningEffort"]
    )
    # Explicit resume target chosen on the phone ("continue a session"). When absent,
    # the bridge starts a fresh session (new task per message) — it no longer
    # auto-resumes by chatId. The id is provider-appropriate (Claude session_id /
    # Codex thread_id); the bridge interprets it per provider.
    |> put_optional_string(
      "resumeSessionId",
      metadata["agentBridgeResumeSessionId"] || metadata["agent_bridge_resume_session_id"] ||
        data["agentBridgeResumeSessionId"]
    )
    # Sealed (arte1) image attachments to hand to the daemon, which decrypts and
    # writes them for the agent to read. Opaque to the server — relayed verbatim.
    |> put_optional_string_list(
      "attachmentsEnc",
      metadata["agentBridgeAttachmentsEnc"] || metadata["agent_bridge_attachments_enc"] ||
        data["agentBridgeAttachmentsEnc"]
    )
  end

  defp normalize_control_action(value) do
    value = normalize_bridge_string(value)

    case value && String.downcase(value) do
      action when action in ["cancel", "stop", "revert"] -> action
      _ -> nil
    end
  end

  defp normalize_bridge_provider(value) do
    value = normalize_bridge_string(value)

    case value && String.downcase(value) do
      provider when provider in ["claude", "codex"] -> provider
      _ -> nil
    end
  end

  defp normalize_bridge_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_bridge_string(_), do: nil

  defp put_optional_string(map, key, value) when is_binary(value) do
    case String.trim(value) do
      "" -> map
      trimmed -> Map.put(map, key, trimmed)
    end
  end

  defp put_optional_string(map, _key, _value), do: map

  defp put_optional_positive_integer(map, key, value) when is_integer(value) and value > 0 do
    Map.put(map, key, min(value, 600))
  end

  defp put_optional_positive_integer(map, key, value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> put_optional_positive_integer(map, key, parsed)
      _ -> map
    end
  end

  defp put_optional_positive_integer(map, _key, _value), do: map

  defp put_optional_string_list(map, key, value) when is_list(value) do
    case Enum.filter(value, &(is_binary(&1) and &1 != "")) do
      [] -> map
      strings -> Map.put(map, key, strings)
    end
  end

  defp put_optional_string_list(map, _key, _value), do: map

  # In a 1:1 chat with a Claude/Codex shadow user, route plain messages (no
  # @mention needed) to that bridge worker — the whole DM is "talk to Claude".
  defp local_worker_for_dm(chat_id, user_id) do
    case Chat.get_room_type(chat_id) do
      "dm" ->
        chat_id
        |> Chat.get_participant_ids()
        |> Enum.reject(&(&1 == user_id))
        |> Enum.find_value(&LocalAgentWorker.resolve_by_agent_user_id/1)

      _ ->
        nil
    end
  end

  defp message_metadata_for_persistence(data, standalone_agent) do
    base_metadata =
      case data["metadata"] do
        value when is_map(value) -> Map.drop(value, @inline_attachment_keys)
        _ -> %{}
      end

    if standalone_agent do
      case normalize_dispatch_text(data["agentText"], data) do
        text when is_binary(text) ->
          Map.put(
            base_metadata,
            "agentInputCiphertext",
            AgentMessageCrypto.encrypt_for_storage(text)
          )

        _ ->
          base_metadata
      end
    else
      base_metadata
    end
  end

  # Remove the sealed image blobs from a broadcast/persist payload (top-level and
  # nested metadata). Leaves everything else untouched.
  defp strip_inline_agent_attachments(%{} = payload) do
    payload
    |> Map.drop(@inline_attachment_keys)
    |> case do
      %{"metadata" => %{} = meta} = stripped ->
        Map.put(stripped, "metadata", Map.drop(meta, @inline_attachment_keys))

      stripped ->
        stripped
    end
  end

  defp strip_inline_agent_attachments(payload), do: payload

  defp broadcast_agent_activity(chat_id, agent_user_id, label, status, tool \\ nil) do
    VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "typing", %{
      "userId" => agent_user_id,
      "isAgent" => true
    })

    payload =
      %{
        "userId" => agent_user_id,
        "isAgent" => true,
        "label" => label,
        "status" => status
      }
      |> then(fn payload ->
        case tool do
          value when is_binary(value) and value != "" -> Map.put(payload, "tool", value)
          _ -> payload
        end
      end)

    VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "agent-progress", payload)
  end

  defp stop_agent_activity(chat_id, agent_user_id) do
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

  defp attachment_context_to_attachments(%{
         image_urls: image_urls,
         document_urls: document_urls,
         audio_urls: audio_urls
       }) do
    image_urls
    |> Enum.map(&%{type: "image", url: &1})
    |> Kernel.++(Enum.map(document_urls, &%{type: "file", url: &1}))
    |> Kernel.++(Enum.map(audio_urls, &%{type: "voice", url: &1}))
  end

  defp extract_agent_attachment_context(chat_id, data, user_id) do
    seeded_images = normalize_urls(data["agentImageUrls"] || data["agent_image_urls"])
    seeded_documents = normalize_urls(data["agentDocumentUrls"] || data["agent_document_urls"])
    seeded_audio = normalize_urls(data["agentAudioUrls"] || data["agent_audio_urls"])

    from_current =
      classify_attachment(
        data["type"] || data["messageType"] || data["message_type"],
        data["mediaUrl"] || data["media_url"]
      )

    reply_media =
      case data["replyToId"] || data["reply_to_id"] do
        reply_id when is_binary(reply_id) and reply_id != "" ->
          case Chat.get_message(chat_id, reply_id, user_id) do
            nil -> nil
            message -> classify_attachment(message.type, message.media_url)
          end

        _ ->
          nil
      end

    image_urls =
      seeded_images
      |> maybe_add_classified_attachment(from_current, :image)
      |> maybe_add_classified_attachment(reply_media, :image)
      |> Enum.uniq()

    document_urls =
      seeded_documents
      |> maybe_add_classified_attachment(from_current, :document)
      |> maybe_add_classified_attachment(reply_media, :document)
      |> Enum.uniq()

    audio_urls =
      seeded_audio
      |> maybe_add_classified_attachment(from_current, :audio)
      |> maybe_add_classified_attachment(reply_media, :audio)
      |> Enum.uniq()

    %{image_urls: image_urls, document_urls: document_urls, audio_urls: audio_urls}
  end

  defp normalize_urls(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_urls(value) when is_binary(value), do: normalize_urls([value])
  defp normalize_urls(_), do: []

  defp maybe_add_classified_attachment(urls, {:image, url}, :image), do: [url | urls]
  defp maybe_add_classified_attachment(urls, {:document, url}, :document), do: [url | urls]
  defp maybe_add_classified_attachment(urls, {:audio, url}, :audio), do: [url | urls]
  defp maybe_add_classified_attachment(urls, _attachment, _kind), do: urls

  defp classify_attachment(raw_type, raw_url) do
    type = normalize_type(raw_type)
    url = normalize_url(raw_url)

    cond do
      is_nil(url) ->
        nil

      type in ["image", "gif", "sticker"] ->
        {:image, url}

      type in ["file", "document", "pdf"] ->
        {:document, url}

      type in ["voice", "audio", "music"] ->
        {:audio, url}

      image_url?(url) ->
        {:image, url}

      document_url?(url) ->
        {:document, url}

      audio_url?(url) ->
        {:audio, url}

      true ->
        nil
    end
  end

  defp normalize_type(raw_type) do
    raw_type
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_url(raw_url) when is_binary(raw_url) do
    trimmed = String.trim(raw_url)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_url(_), do: nil

  defp image_url?(url) when is_binary(url) do
    lower = String.downcase(url)

    Enum.any?(
      [".png", ".jpg", ".jpeg", ".webp", ".gif", ".heic", ".bmp"],
      &String.contains?(lower, &1)
    )
  end

  defp document_url?(url) when is_binary(url) do
    lower = String.downcase(url)

    Enum.any?(
      [".pdf", ".doc", ".docx", ".ppt", ".pptx", ".xls", ".xlsx", ".txt", ".rtf", ".md"],
      &String.contains?(lower, &1)
    )
  end

  defp audio_url?(url) when is_binary(url) do
    lower = String.downcase(url)

    Enum.any?(
      [".mp3", ".m4a", ".aac", ".wav", ".ogg", ".oga", ".opus", ".flac"],
      &String.contains?(lower, &1)
    )
  end

  defp enforce_sender_identity(payload, user_id) when is_map(payload) do
    payload
    |> Map.put("fromId", user_id)
    |> Map.put("from_id", user_id)
  end

  defp deobfuscate(%{"d" => encoded}) do
    encoded
    |> Base.decode64!(ignore: :whitespace)
    |> Jason.decode!()
  end

  # Fallback if not obfuscated
  defp deobfuscate(map), do: map
end
