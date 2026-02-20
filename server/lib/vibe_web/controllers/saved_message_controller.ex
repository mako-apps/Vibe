defmodule VibeWeb.SavedMessageController do
  use VibeWeb, :controller
  alias Vibe.Chat

  def index(conn, %{"user_id" => user_id}) do
    current_id = conn.assigns.current_user.id

    if user_id != current_id do
      conn |> put_status(:forbidden) |> json(%{error: "Forbidden"})
    else
      messages = Chat.list_saved_messages(current_id)
      json(conn, %{data: messages})
    end
  end

  def create(conn, params) do
    attrs = Map.put(params, "user_id", conn.assigns.current_user.id)

    case Chat.save_message(attrs) do
      {:ok, message} -> json(conn, %{data: message})
      {:error, _changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "Failed to save"})
    end
  end

  def delete(conn, %{"user_id" => user_id, "original_message_id" => id}) do
    current_id = conn.assigns.current_user.id

    if user_id != current_id do
      conn |> put_status(:forbidden) |> json(%{error: "Forbidden"})
    else
      Chat.unsave_message(current_id, id)
      json(conn, %{success: true})
    end
  end
end
