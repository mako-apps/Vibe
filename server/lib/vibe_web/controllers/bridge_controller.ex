defmodule VibeWeb.BridgeController do
  use VibeWeb, :controller

  alias Vibe.ChatBridge

  def bundle(conn, _params) do
    case ChatBridge.bundle() do
      {:ok, bundle} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> json(bundle)

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "bridge_bundle_missing"})

      {:error, :invalid_bundle} ->
        conn |> put_status(:internal_server_error) |> json(%{error: "bridge_bundle_invalid"})
    end
  end

  def open_session(conn, params) do
    with {:ok, payload} <- ChatBridge.open_session(conn.assigns.current_user, params) do
      json(conn, payload)
    else
      error -> render_bridge_error(conn, error)
    end
  end

  def send(conn, params) do
    with {:ok, payload} <- ChatBridge.send_event(conn.assigns.current_user, params) do
      json(conn, payload)
    else
      error -> render_bridge_error(conn, error)
    end
  end

  def poll(conn, params) do
    with {:ok, payload} <- ChatBridge.poll(conn.assigns.current_user, params) do
      json(conn, payload)
    else
      error -> render_bridge_error(conn, error)
    end
  end

  def ack(conn, params) do
    with {:ok, payload} <- ChatBridge.ack_event(conn.assigns.current_user, params) do
      json(conn, payload)
    else
      error -> render_bridge_error(conn, error)
    end
  end

  def home_snapshot(conn, params) do
    with {:ok, payload} <- ChatBridge.home_snapshot(conn.assigns.current_user, params) do
      json(conn, payload)
    else
      error -> render_bridge_error(conn, error)
    end
  end

  def chat_history(conn, params) do
    with {:ok, payload} <- ChatBridge.chat_history(conn.assigns.current_user, params) do
      json(conn, payload)
    else
      error -> render_bridge_error(conn, error)
    end
  end

  def peer_key(conn, params) do
    with {:ok, payload} <- ChatBridge.peer_key(conn.assigns.current_user, params) do
      json(conn, payload)
    else
      error -> render_bridge_error(conn, error)
    end
  end

  defp render_bridge_error(conn, {:error, :bad_request}) do
    conn |> put_status(:bad_request) |> json(%{error: "bad_request"})
  end

  defp render_bridge_error(conn, {:error, :forbidden}) do
    conn |> put_status(:forbidden) |> json(%{error: "forbidden"})
  end

  defp render_bridge_error(conn, {:error, :not_found}) do
    conn |> put_status(:not_found) |> json(%{error: "not_found"})
  end

  defp render_bridge_error(conn, {:error, :conflict}) do
    conn |> put_status(:conflict) |> json(%{error: "conflict"})
  end

  defp render_bridge_error(conn, {:error, :unprocessable_entity}) do
    conn |> put_status(:unprocessable_entity) |> json(%{error: "unprocessable_entity"})
  end

  defp render_bridge_error(conn, {:error, reason}) do
    conn |> put_status(:bad_request) |> json(%{error: to_string(reason)})
  end
end
