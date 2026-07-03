defmodule VibeWeb.VibeagentController do
  use VibeWeb, :controller
  require Logger

  alias Vibe.AI.AgentBuilder
  alias Vibe.AI.AgenticEventShape

  def session(conn, _params) do
    user_id = conn.assigns.current_user.id

    case AgentBuilder.session_payload(user_id) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  def chat(conn, params) do
    user_id = conn.assigns.current_user.id
    active_agent_id = params["activeAgentId"] || params["active_agent_id"]
    message = normalize_optional_string(params["message"])
    ui_response = params["uiResponse"] || params["ui_response"]

    cond do
      is_binary(message) or is_map(ui_response) ->
        case AgentBuilder.handle_message(
               user_id,
               message,
               active_agent_id: active_agent_id,
               ui_response: ui_response
             ) do
          {:ok, payload} ->
            json(conn, payload)

          {:error, reason} ->
            conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
        end

      true ->
        conn |> put_status(:bad_request) |> json(%{error: "message or uiResponse is required"})
    end
  end

  def chat_stream(conn, params) do
    user_id = conn.assigns.current_user.id
    active_agent_id = params["activeAgentId"] || params["active_agent_id"]
    message = normalize_optional_string(params["message"])
    ui_response = params["uiResponse"] || params["ui_response"]

    if is_binary(message) or is_map(ui_response) do
      conn =
        conn
        |> put_resp_content_type("text/event-stream")
        |> put_resp_header("cache-control", "no-cache")
        |> put_resp_header("connection", "keep-alive")
        |> send_chunked(200)

      callback = fn
        %{type: :text, content: chunk} ->
          send_sse_event(conn, "chunk", AgenticEventShape.enrich("chunk", %{text: chunk}))

        %{type: :progress} = payload ->
          send_sse_event(
            conn,
            "progress",
            AgenticEventShape.enrich("progress", Map.delete(payload, :type))
          )

        %{type: :tool_result} = payload ->
          send_sse_event(
            conn,
            "tool_result",
            AgenticEventShape.enrich("tool_result", Map.delete(payload, :type))
          )

        %{type: :state, data: data} ->
          send_sse_event(conn, "state", AgenticEventShape.enrich("state", data))

        %{type: :ui_request, data: data} ->
          send_sse_event(conn, "ui_request", AgenticEventShape.enrich("ui_request", data))

        %{type: :draft_patch, data: data} ->
          send_sse_event(conn, "draft_patch", AgenticEventShape.enrich("draft_patch", data))

        %{type: :review_ready, data: data} ->
          send_sse_event(conn, "review_ready", AgenticEventShape.enrich("review_ready", data))
      end

      case AgentBuilder.stream_message(
             user_id,
             message,
             callback,
             active_agent_id: active_agent_id,
             ui_response: ui_response
           ) do
        {:ok, payload} ->
          send_sse_event(conn, "done", AgenticEventShape.enrich("done", payload))

        {:error, reason} ->
          send_sse_event(
            conn,
            "error",
            AgenticEventShape.enrich("error", %{message: to_string(reason)})
          )
      end

      conn
    else
      conn |> put_status(:bad_request) |> json(%{error: "message or uiResponse is required"})
    end
  end

  defp send_sse_event(conn, event, data) do
    chunk = "event: #{event}\ndata: #{Jason.encode!(data)}\n\n"

    case Plug.Conn.chunk(conn, chunk) do
      {:ok, _conn} -> :ok
      {:error, reason} -> Logger.warning("Vibeagent SSE chunk failed: #{inspect(reason)}")
    end
  end

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(_value), do: nil
end
