defmodule VibeWeb.ChatController do
  use VibeWeb, :controller
  alias Vibe.Chat
  alias Vibe.Accounts

  def create(conn, %{"friendId" => friend_id}) do
    my_id = conn.assigns.current_user.id

    # Validate friend exists to avoid foreign key errors.
    if is_nil(Accounts.get_user(friend_id)) do
      conn |> put_status(:not_found) |> json(%{error: "User not found"})
    else
    # Check if chat already exists
    case Chat.find_chat_between_users(my_id, friend_id) do
      id when not is_nil(id) ->
        # Check if user previously deleted this chat
        case Chat.restore_if_deleted(id, my_id) do
          :restored ->
            # Chat was deleted, now restored - return empty messages (fresh start)
            json(conn, %{chatId: id, messages: []})
          :not_deleted ->
            # Chat exists and wasn't deleted - return existing messages
            messages = Chat.get_messages(id)
            json(conn, %{chatId: id, messages: messages})
        end

      nil ->
        # Deterministic chat id to make chat creation idempotent and avoid duplicates on concurrent requests.
        # Uses first 12 hex chars of SHA256(sort([my_id, friend_id])).
        chat_id =
          :crypto.hash(:sha256, Enum.sort([my_id, friend_id]) |> Enum.join("|"))
          |> Base.encode16(case: :lower)
          |> binary_part(0, 12)

        try do
          case Chat.create_chat(chat_id, [my_id, friend_id]) do
            {:ok, _chat} ->
              json(conn, %{chatId: chat_id, messages: []})

            _ ->
              conn |> put_status(500) |> json(%{error: "Failed to create chat"})
          end
        rescue
          Ecto.ConstraintError ->
            # Another request created the chat first; return the existing chat id.
            messages = Chat.get_messages(chat_id)
            json(conn, %{chatId: chat_id, messages: messages})
        end
    end
    end
  end

  def messages(conn, %{"chat_id" => chat_id}) do
    user_id = conn.assigns.current_user.id

    if Chat.is_participant?(chat_id, user_id) do
      messages = Chat.get_messages_for_user(chat_id, user_id)
      json(conn, messages) # Use json directly instead of render for pure API parity
    else
      conn |> put_status(:forbidden) |> json(%{error: "Not a participant"})
    end
  end

  def delete_message(conn, %{"chat_id" => chat_id, "message_id" => message_id} = params) do
    user_id = conn.assigns.current_user.id
    for_everyone =
      case Map.get(params, "for_everyone", true) do
        v when v in [true, "true", "1", 1] -> true
        _ -> false
      end

    case Chat.delete_message(chat_id, message_id, user_id, for_everyone) do
      {:ok, _message} ->
        VibeWeb.Endpoint.broadcast!("chat:#{chat_id}", "message-deleted", %{
          messageId: message_id,
          deletedBy: user_id,
          forEveryone: for_everyone
        })

        json(conn, %{success: true, messageId: message_id, forEveryone: for_everyone})

      {:error, :invalid_id} ->
        conn |> put_status(:bad_request) |> json(%{error: "Invalid message id"})

      {:error, :forbidden} ->
        conn |> put_status(:forbidden) |> json(%{error: "Not allowed"})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Message not found"})

      {:error, reason} ->
        conn |> put_status(:bad_request) |> json(%{error: inspect(reason)})
    end
  end

  def list_pinned_messages(conn, %{"chat_id" => chat_id}) do
    user_id = conn.assigns.current_user.id

    if Chat.is_participant?(chat_id, user_id) do
      pins = Chat.list_pinned_messages(chat_id, user_id)
      json(conn, %{data: pins})
    else
      conn |> put_status(:forbidden) |> json(%{error: "Not a participant"})
    end
  end

  def pin_message(conn, %{"chat_id" => chat_id, "message_id" => message_id} = params) do
    user_id = conn.assigns.current_user.id

    pinned =
      case Map.get(params, "pinned", true) do
        v when v in [true, "true", "1", 1] -> true
        _ -> false
      end

    case Chat.set_message_pin(chat_id, message_id, user_id, pinned) do
      {:ok, :unpinned} ->
        json(conn, %{success: true, pinned: false, messageId: message_id})

      {:ok, _pin} ->
        json(conn, %{success: true, pinned: true, messageId: message_id})

      {:error, :invalid_id} ->
        conn |> put_status(:bad_request) |> json(%{error: "Invalid message id"})

      {:error, :forbidden} ->
        conn |> put_status(:forbidden) |> json(%{error: "Not allowed"})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Message not found"})

      {:error, reason} ->
        conn |> put_status(:bad_request) |> json(%{error: inspect(reason)})
    end
  end

  def index(conn, %{"user_id" => user_id}) do
    current_id = conn.assigns.current_user.id

    if user_id != current_id do
      conn |> put_status(:forbidden) |> json(%{error: "Forbidden"})
    else
      chats = Chat.list_chats(current_id)
      json(conn, chats)
    end
  end

  def mute(conn, %{"chat_id" => chat_id, "muted" => muted}) do
    user_id = conn.assigns.current_user.id

    if Chat.is_participant?(chat_id, user_id) do
      {count, _} = Chat.set_muted(chat_id, user_id, muted)
      json(conn, %{success: count > 0})
    else
      conn |> put_status(:forbidden) |> json(%{error: "Not a participant"})
    end
  end

  def pin(conn, %{"chat_id" => chat_id, "pinned" => pinned}) do
    user_id = conn.assigns.current_user.id

    if Chat.is_participant?(chat_id, user_id) do
      {count, _} = Chat.set_pinned(chat_id, user_id, pinned)
      json(conn, %{success: count > 0})
    else
      conn |> put_status(:forbidden) |> json(%{error: "Not a participant"})
    end
  end

  def mark_unread(conn, %{"chat_id" => chat_id, "unread" => unread}) do
    user_id = conn.assigns.current_user.id

    if Chat.is_participant?(chat_id, user_id) do
      {count, _} = Chat.set_marked_unread(chat_id, user_id, unread)
      json(conn, %{success: count > 0})
    else
      conn |> put_status(:forbidden) |> json(%{error: "Not a participant"})
    end
  end

  def delete(conn, %{"chat_id" => chat_id}) do
    user_id = conn.assigns.current_user.id

    if Chat.is_participant?(chat_id, user_id) do
      case Chat.delete_chat(chat_id, user_id) do
        {:ok, _} -> json(conn, %{success: true})
        {:error, reason} -> conn |> put_status(400) |> json(%{error: reason})
      end
    else
      conn |> put_status(:forbidden) |> json(%{error: "Not a participant"})
    end
  end
end
