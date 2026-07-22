defmodule Vibe.AI.Tools.Channel do
  @moduledoc """
  Agent tools for channel management: posting, analytics, and scheduling.
  """

  require Logger
  alias Vibe.Accounts
  alias Vibe.Agents
  alias Vibe.Chat
  alias Vibe.Notifications

  @doc "Creates a group or channel owned by the current agent owner."
  def create_chat_space(input, agent_id, requester_user_id) when is_map(input) do
    with {:ok, agent} <- resolve_owned_agent(agent_id, requester_user_id),
         {:ok, room_type} <- normalize_room_type(input),
         {:ok, name} <- required_string(input["name"], :invalid_name),
         member_ids <-
           input
           |> then(&(&1["member_ids"] || &1["memberIds"]))
           |> normalize_id_list()
           |> Enum.reject(&(&1 in [requester_user_id, agent.agent_user_id])),
         :ok <- validate_member_ids(member_ids),
         attach? <-
           normalize_boolean(
             input_value(input, "attach_current_agent", "attachCurrentAgent"),
             true
           ),
         {:ok, room} <-
           create_space(
             room_type,
             requester_user_id,
             agent,
             input,
             name,
             member_ids,
             attach?
           ) do
      %{
        "ok" => true,
        "room" => canonical_tool_room(room),
        "attached_current_agent" => attach?
      }
    else
      {:error, reason} -> %{"ok" => false, "error" => error_message(reason)}
    end
  end

  def create_chat_space(_input, _agent_id, _requester_user_id),
    do: %{"ok" => false, "error" => "Invalid room input."}

  @doc "Attaches the current owned agent to an owned group or channel."
  def attach_current_agent_to_chat(input, agent_id, requester_user_id) when is_map(input) do
    chat_id = normalize_string(input["chat_id"] || input["chatId"])

    with {:ok, agent} <- resolve_owned_agent(agent_id, requester_user_id),
         true <- is_binary(chat_id) || {:error, :invalid_chat_id},
         "owner" <- Chat.get_user_role(chat_id, requester_user_id) || {:error, :not_owned},
         room when not is_nil(room) <- Chat.get_chat(chat_id) || {:error, :not_found},
         {:ok, attachment} <- attach_agent(room.type, room.id, agent, requester_user_id, input) do
      %{
        "ok" => true,
        "chat_id" => room.id,
        "room_type" => room.type,
        "chat_link" => chat_link(room.id),
        "agent_id" => agent.id,
        "agent_user_id" => agent.agent_user_id,
        "attachment" => attachment
      }
    else
      {:error, reason} -> %{"ok" => false, "error" => error_message(reason)}
      _ -> %{"ok" => false, "error" => "Only an owned group or channel can be changed."}
    end
  end

  def attach_current_agent_to_chat(_input, _agent_id, _requester_user_id),
    do: %{"ok" => false, "error" => "Invalid room input."}

  def post_to_channel(input, user_id) do
    channel_id = input["channel_id"]
    content = input["content"]
    type = input["type"] || "text"
    media_url = input["media_url"]

    # Verify user owns the channel
    case Chat.get_user_role(channel_id, user_id) do
      role when role in ["owner", "admin"] ->
        message_id = Ecto.UUID.generate()
        timestamp = :os.system_time(:millisecond)

        message_attrs = %{
          id: message_id,
          chat_id: channel_id,
          from_id: user_id,
          encrypted_content: content,
          type: type,
          media_url: media_url,
          timestamp: timestamp
        }

        case Chat.add_message(message_attrs) do
          {:ok, _msg} ->
            # Broadcast to channel subscribers
            VibeWeb.Endpoint.broadcast!("chat:#{channel_id}", "message", %{
              "id" => message_id,
              "fromId" => user_id,
              "encryptedContent" => content,
              "type" => type,
              "mediaUrl" => media_url,
              "timestamp" => timestamp
            })

            # Notify subscribers
            Chat.get_participant_ids(channel_id)
            |> Enum.each(fn pid ->
              if pid != user_id do
                VibeWeb.Endpoint.broadcast!("user:#{pid}", "new_message", %{
                  chat_id: channel_id,
                  from_id: user_id,
                  message_id: message_id,
                  timestamp: timestamp
                })

                _ =
                  Notifications.send_message_push(pid, %{
                    "chat_id" => channel_id,
                    "from_id" => user_id,
                    "message_id" => message_id
                  })
              end
            end)

            %{success: true, message: "Posted to channel", message_id: message_id}

          {:error, reason} ->
            %{error: "Failed to post: #{inspect(reason)}"}
        end

      _ ->
        %{error: "You don't own this channel"}
    end
  end

  @doc "Posts to an attached channel as the current standalone agent."
  def post_to_channel(input, agent_id, requester_user_id) when is_map(input) do
    channel_id = normalize_string(input["channel_id"] || input["channelId"])

    with {:ok, agent} <- resolve_owned_agent(agent_id, requester_user_id),
         true <- is_binary(channel_id) || {:error, :invalid_chat_id},
         "channel" <- Chat.get_room_type(channel_id) || {:error, :not_found},
         requester_role when requester_role in ["owner", "admin"] <-
           Chat.get_user_role(channel_id, requester_user_id) || {:error, :not_authorized},
         "agent_admin" <-
           Chat.get_user_role(channel_id, agent.agent_user_id) || {:error, :agent_not_attached} do
      post_message_to_channel(input, channel_id, agent.agent_user_id, agent)
    else
      {:error, reason} -> %{"ok" => false, "error" => error_message(reason)}
      _ -> %{"ok" => false, "error" => "The agent is not attached to this channel as an admin."}
    end
  end

  def post_to_channel(_input, _agent_id, _requester_user_id),
    do: %{"ok" => false, "error" => "Invalid channel post."}

  defp post_message_to_channel(input, channel_id, sender_id, agent) do
    content = input["content"]
    type = input["type"] || "text"
    media_url = input["media_url"] || input["mediaUrl"]
    message_id = Ecto.UUID.generate()
    timestamp = :os.system_time(:millisecond)

    metadata = %{
      "isAgentMessage" => true,
      "agentId" => agent.id,
      "agentName" => agent.display_name,
      "agentUserId" => agent.agent_user_id
    }

    message_attrs = %{
      id: message_id,
      chat_id: channel_id,
      from_id: sender_id,
      encrypted_content: content,
      type: type,
      media_url: media_url,
      metadata: metadata,
      timestamp: timestamp
    }

    case Chat.add_message(message_attrs, acting_user_id: sender_id) do
      {:ok, _message} ->
        payload = %{
          "id" => message_id,
          "fromId" => sender_id,
          "encryptedContent" => content,
          "type" => type,
          "mediaUrl" => media_url,
          "timestamp" => timestamp,
          "isAgentMessage" => true,
          "agentId" => agent.id,
          "agentName" => agent.display_name,
          "agentUserId" => agent.agent_user_id,
          "metadata" => metadata
        }

        VibeWeb.Endpoint.broadcast!("chat:#{channel_id}", "message", payload)
        notify_channel_participants(channel_id, sender_id, message_id, timestamp)

        %{
          "ok" => true,
          "message" => "Posted to channel as the agent.",
          "message_id" => message_id,
          "from_id" => sender_id
        }

      {:error, reason} ->
        %{"ok" => false, "error" => "Failed to post: #{inspect(reason)}"}
    end
  end

  defp notify_channel_participants(channel_id, sender_id, message_id, timestamp) do
    Chat.get_participant_ids(channel_id)
    |> Enum.each(fn participant_id ->
      if participant_id != sender_id do
        VibeWeb.Endpoint.broadcast!("user:#{participant_id}", "new_message", %{
          chat_id: channel_id,
          from_id: sender_id,
          message_id: message_id,
          timestamp: timestamp
        })

        _ =
          Notifications.send_message_push(participant_id, %{
            "chat_id" => channel_id,
            "from_id" => sender_id,
            "message_id" => message_id
          })
      end
    end)
  end

  def get_analytics(input, user_id) do
    channel_id = input["channel_id"]

    # Verify user has access
    case Chat.get_user_role(channel_id, user_id) do
      role when role in ["owner", "admin"] ->
        analytics = Chat.get_channel_analytics(channel_id, user_id)
        %{success: true, analytics: analytics}

      _ ->
        %{error: "You don't have access to this channel's analytics"}
    end
  end

  def schedule_post(input, user_id) do
    channel_id = input["channel_id"]

    # Verify user owns the channel
    case Chat.get_user_role(channel_id, user_id) do
      role when role in ["owner", "admin"] ->
        scheduled_at =
          case DateTime.from_iso8601(input["scheduled_at"]) do
            {:ok, dt, _} -> dt
            _ -> nil
          end

        if is_nil(scheduled_at) do
          %{error: "Invalid scheduled_at datetime. Use ISO8601 format."}
        else
          attrs = %{
            channel_id: channel_id,
            user_id: user_id,
            content: input["content"],
            type: input["type"] || "text",
            media_url: input["media_url"],
            scheduled_at: scheduled_at
          }

          case Vibe.Scheduler.schedule_post(attrs) do
            {:ok, post} ->
              %{
                success: true,
                message: "Post scheduled",
                post_id: post.id,
                scheduled_at: to_string(post.scheduled_at)
              }

            {:error, reason} ->
              %{error: "Failed to schedule: #{inspect(reason)}"}
          end
        end

      _ ->
        %{error: "You don't own this channel"}
    end
  end

  @doc "Schedules a post under the attached standalone agent's sender identity."
  def schedule_post(input, agent_id, requester_user_id) when is_map(input) do
    channel_id = normalize_string(input["channel_id"] || input["channelId"])

    with {:ok, agent} <- resolve_owned_agent(agent_id, requester_user_id),
         true <- is_binary(channel_id) || {:error, :invalid_chat_id},
         "channel" <- Chat.get_room_type(channel_id) || {:error, :not_found},
         requester_role when requester_role in ["owner", "admin"] <-
           Chat.get_user_role(channel_id, requester_user_id) || {:error, :not_authorized},
         "agent_admin" <-
           Chat.get_user_role(channel_id, agent.agent_user_id) || {:error, :agent_not_attached},
         {:ok, scheduled_at, _offset} <-
           DateTime.from_iso8601(input["scheduled_at"] || input["scheduledAt"] || ""),
         {:ok, post} <-
           Vibe.Scheduler.schedule_post(%{
             channel_id: channel_id,
             user_id: agent.agent_user_id,
             content: input["content"],
             type: input["type"] || "text",
             media_url: input["media_url"] || input["mediaUrl"],
             scheduled_at: scheduled_at
           }) do
      %{
        "ok" => true,
        "message" => "Agent post scheduled.",
        "post_id" => post.id,
        "scheduled_at" => to_string(post.scheduled_at),
        "from_id" => agent.agent_user_id
      }
    else
      {:error, :invalid_format} ->
        %{"ok" => false, "error" => "Invalid scheduled_at datetime. Use ISO8601 format."}

      {:error, reason} ->
        %{"ok" => false, "error" => error_message(reason)}

      _ ->
        %{"ok" => false, "error" => "The agent is not attached to this channel as an admin."}
    end
  end

  def schedule_post(_input, _agent_id, _requester_user_id),
    do: %{"ok" => false, "error" => "Invalid scheduled post."}

  defp create_space("group", requester_user_id, agent, input, name, member_ids, attach?) do
    with {:ok, room} <-
           Chat.create_group(
             requester_user_id,
             name,
             member_ids,
             normalize_string(input["avatar_url"] || input["avatarUrl"]),
             normalize_string(input["description"])
           ),
         {:ok, _attachment} <- maybe_attach_group(room.id, agent, requester_user_id, attach?) do
      {:ok, Chat.canonical_room_summary(Chat.get_chat(room.id), role: "owner")}
    end
  end

  defp create_space("channel", requester_user_id, agent, input, name, member_ids, attach?) do
    attrs = %{
      "name" => name,
      "description" => normalize_string(input["description"]),
      "avatarUrl" => normalize_string(input["avatar_url"] || input["avatarUrl"]),
      "memberIds" => member_ids,
      "accessType" => normalize_string(input["access_type"] || input["accessType"]) || "private",
      "publicSlug" => normalize_string(input["public_slug"] || input["publicSlug"]),
      "joinApprovalRequired" =>
        normalize_boolean(
          input_value(input, "join_approval_required", "joinApprovalRequired"),
          false
        ),
      "restrictSavingContent" =>
        normalize_boolean(
          input_value(
            input,
            "restrict_saving",
            "restrictSaving",
            "restrict_saving_content",
            "restrictSavingContent"
          ),
          false
        ),
      "agentAdminIds" => if(attach?, do: [agent.id], else: [])
    }

    Chat.create_channel(requester_user_id, attrs)
  end

  defp maybe_attach_group(_chat_id, _agent, _requester_user_id, false), do: {:ok, nil}

  defp maybe_attach_group(chat_id, agent, requester_user_id, true) do
    Chat.add_member(chat_id, agent.agent_user_id, "member", actor_id: requester_user_id)
  end

  defp attach_agent("group", chat_id, agent, requester_user_id, _input) do
    with {:ok, _participant} <-
           Chat.add_member(chat_id, agent.agent_user_id, "member", actor_id: requester_user_id) do
      {:ok, %{"role" => "member"}}
    end
  end

  defp attach_agent("channel", chat_id, agent, requester_user_id, input) do
    attrs =
      %{}
      |> maybe_put("allowedTools", input["allowed_tools"] || input["allowedTools"])
      |> maybe_put(
        "allowedOutputModes",
        input["allowed_output_modes"] || input["allowedOutputModes"]
      )
      |> maybe_put("permissions", input["permissions"])

    Chat.attach_channel_agent(chat_id, requester_user_id, agent.id, attrs)
  end

  defp attach_agent(_type, _chat_id, _agent, _requester_user_id, _input),
    do: {:error, :invalid_room_type}

  defp canonical_tool_room(room) when is_map(room) do
    chat_id = room[:chatId] || room["chatId"]

    %{
      "chat_id" => chat_id,
      "room_type" => room[:type] || room["type"],
      "name" => room[:name] || room["name"],
      "description" => room[:description] || room["description"],
      "avatar_url" => room[:avatarUrl] || room["avatarUrl"],
      "member_count" => room[:memberCount] || room["memberCount"],
      "access_type" => room[:accessType] || room["accessType"],
      "public_slug" => room[:publicSlug] || room["publicSlug"],
      "share_link" => room[:shareLink] || room["shareLink"],
      "chat_link" => chat_link(chat_id)
    }
  end

  defp resolve_owned_agent(agent_id, requester_user_id)
       when is_binary(agent_id) and is_binary(requester_user_id) do
    case Agents.get_agent(agent_id, requester_user_id) do
      nil -> {:error, :not_owned}
      agent -> {:ok, agent}
    end
  end

  defp resolve_owned_agent(_, _), do: {:error, :owner_lookup_required}

  defp normalize_room_type(input) do
    case normalize_string(input["room_type"] || input["roomType"]) do
      value when value in ["group", "channel"] -> {:ok, value}
      _ -> {:error, :invalid_room_type}
    end
  end

  defp required_string(value, error) do
    case normalize_string(value) do
      nil -> {:error, error}
      string -> {:ok, string}
    end
  end

  defp normalize_id_list(value) when is_list(value) do
    value
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_id_list(_), do: []

  defp validate_member_ids(member_ids) do
    if Enum.all?(member_ids, fn member_id ->
         case Accounts.get_user(member_id) do
           %{is_agent: false} -> true
           _ -> false
         end
       end) do
      :ok
    else
      {:error, :invalid_member_ids}
    end
  end

  defp normalize_boolean(nil, default), do: default
  defp normalize_boolean(value, _default) when value in [true, "true", "1", 1], do: true
  defp normalize_boolean(_value, _default), do: false

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp input_value(input, key_a, key_b) do
    if Map.has_key?(input, key_a), do: input[key_a], else: input[key_b]
  end

  defp input_value(input, key_a, key_b, key_c, key_d) do
    Enum.find_value([key_a, key_b, key_c, key_d], fn key ->
      if Map.has_key?(input, key), do: {:found, input[key]}
    end)
    |> case do
      {:found, value} -> value
      nil -> nil
    end
  end

  defp chat_link(chat_id), do: "vibe://chat?chatId=#{URI.encode_www_form(chat_id)}"

  defp error_message(:owner_lookup_required), do: "Owner identity is required."
  defp error_message(:not_owned), do: "Only the agent owner can change rooms."
  defp error_message(:invalid_name), do: "Room name is required."
  defp error_message(:invalid_chat_id), do: "Chat id is required."
  defp error_message(:invalid_member_ids), do: "member_ids contains an unknown user."
  defp error_message(:invalid_room_type), do: "room_type must be group or channel."
  defp error_message(:not_found), do: "Room not found."
  defp error_message(:not_authorized), do: "Only a room owner can attach this agent."
  defp error_message(:agent_not_owned), do: "The current agent is not owned by this user."
  defp error_message(:agent_not_attached), do: "Attach this agent as a channel admin first."
  defp error_message(reason), do: inspect(reason)
end
