defmodule VibeWeb.VibeagentController do
  use VibeWeb, :controller
  require Logger

  alias Vibe.AI.AgentBuilder

  def session(conn, _params) do
    user_id = conn.assigns.current_user.id

    case AgentBuilder.session_payload(user_id) do
      {:ok, payload} -> json(conn, payload)
      {:error, reason} -> conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  def chat(conn, %{"message" => message} = params) do
    user_id = conn.assigns.current_user.id
    active_agent_id = params["activeAgentId"] || params["active_agent_id"]

    case AgentBuilder.handle_message(user_id, message, active_agent_id: active_agent_id) do
      {:ok, payload} -> json(conn, payload)
      {:error, reason} -> conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  def chat(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "message is required"})
  end

  def chat_stream(conn, %{"message" => message} = params) do
    user_id = conn.assigns.current_user.id
    active_agent_id = params["activeAgentId"] || params["active_agent_id"]

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    callback = fn
      %{type: :text, content: chunk} ->
        send_sse_event(conn, "chunk", %{text: chunk})
    end

    case AgentBuilder.stream_message(user_id, message, callback, active_agent_id: active_agent_id) do
      {:ok, payload} ->
        send_sse_event(conn, "done", payload)

      {:error, reason} ->
        send_sse_event(conn, "error", %{message: to_string(reason)})
    end

    conn
  end

  def chat_stream(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "message is required"})
  end

  defp send_sse_event(conn, event, data) do
    chunk = "event: #{event}\ndata: #{Jason.encode!(data)}\n\n"

    case Plug.Conn.chunk(conn, chunk) do
      {:ok, _conn} -> :ok
      {:error, reason} -> Logger.warning("Vibeagent SSE chunk failed: #{inspect(reason)}")
    end
  end
end
