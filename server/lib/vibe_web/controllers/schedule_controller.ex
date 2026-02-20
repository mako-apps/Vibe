defmodule VibeWeb.ScheduleController do
  use VibeWeb, :controller
  alias Vibe.Chat

  def create(conn, %{"id" => channel_id} = params) do
    requester_id = conn.assigns.current_user.id
    settings = Chat.get_participant_settings(channel_id, requester_id)

    if settings && settings.role in ["owner", "admin"] do
    attrs = %{
      channel_id: channel_id,
      user_id: requester_id,
      content: params["content"],
      type: params["type"] || "text",
      media_url: params["mediaUrl"],
      scheduled_at: parse_datetime(params["scheduledAt"])
    }

    case Vibe.Scheduler.schedule_post(attrs) do
      {:ok, post} ->
        json(conn, %{
          id: post.id,
          channelId: post.channel_id,
          content: post.content,
          type: post.type,
          scheduledAt: post.scheduled_at,
          status: post.status
        })

      {:error, reason} ->
        conn |> put_status(400) |> json(%{error: "Failed to schedule: #{inspect(reason)}"})
    end
    else
      conn |> put_status(:forbidden) |> json(%{error: "Not authorized"})
    end
  end

  def list(conn, %{"id" => channel_id}) do
    requester_id = conn.assigns.current_user.id

    if Chat.is_participant?(channel_id, requester_id) do
      posts = Chat.list_scheduled_posts(channel_id)

      json(conn, Enum.map(posts, fn post ->
        %{
          id: post.id,
          content: post.content,
          type: post.type,
          mediaUrl: post.media_url,
          scheduledAt: post.scheduled_at,
          status: post.status
        }
      end))
    else
      conn |> put_status(:forbidden) |> json(%{error: "Not a participant"})
    end
  end

  def cancel(conn, %{"id" => post_id}) do
    user_id = conn.assigns.current_user.id

    case Vibe.Scheduler.cancel_post(post_id, user_id) do
      :ok -> json(conn, %{success: true})
      {:error, reason} -> conn |> put_status(400) |> json(%{error: reason})
    end
  end

  defp parse_datetime(nil), do: nil
  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
  defp parse_datetime(_), do: nil
end
