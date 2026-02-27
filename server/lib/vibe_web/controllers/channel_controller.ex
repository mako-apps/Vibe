defmodule VibeWeb.ChannelController do
  use VibeWeb, :controller
  alias Vibe.Chat

  def create(conn, %{"name" => name} = params) do
    creator_id = conn.assigns.current_user.id
    description = params["description"]

    case Chat.create_channel(creator_id, name, description) do
      {:ok, room} ->
        json(conn, %{
          chatId: room.id,
          type: "channel",
          name: room.name,
          description: room.description,
          creatorId: room.creator_id
        })

      {:error, reason} ->
        conn |> put_status(500) |> json(%{error: "Failed to create channel: #{inspect(reason)}"})
    end
  end

  def index(conn, _params) do
    channels = Chat.list_channels()
    json(conn, channels)
  end

  def join(conn, %{"id" => channel_id}) do
    user_id = conn.assigns.current_user.id
    case Chat.join_channel(channel_id, user_id) do
      {:ok, _} -> json(conn, %{success: true})
      {:error, reason} -> conn |> put_status(400) |> json(%{error: reason})
    end
  end

  def leave(conn, %{"id" => channel_id}) do
    user_id = conn.assigns.current_user.id
    case Chat.leave_channel(channel_id, user_id) do
      {:ok, _} -> json(conn, %{success: true})
      {:error, reason} -> conn |> put_status(400) |> json(%{error: reason})
    end
  end

  def analytics(conn, %{"id" => channel_id}) do
    user_id = conn.assigns.current_user.id

    case Chat.get_user_role(channel_id, user_id) do
      role when role in ["owner", "admin"] ->
        analytics = Chat.get_channel_analytics(channel_id, user_id)
        json(conn, analytics)

      _ ->
        conn |> put_status(:forbidden) |> json(%{error: "Not allowed"})
    end
  end
end
