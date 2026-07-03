defmodule Vibe.AI.AgenticEventShape do
  @moduledoc false

  @schema "vibe.agentic.v1"

  def enrich(event, payload) do
    event = to_string(event)
    payload = ensure_map(payload)
    nodes = progress_nodes(event, payload)

    payload
    |> Map.put_new(:agenticSchema, @schema)
    |> Map.put_new(:agentic_schema, @schema)
    |> Map.put_new(:response_item, response_item(event, payload))
    |> Map.put_new(:responseItem, response_item(event, payload))
    |> Map.put_new(:progressNodes, nodes)
    |> Map.put_new(:progress_nodes, nodes)
    |> Map.put_new(:terminal, terminal?(event))
  end

  defp response_item("chunk", payload) do
    text = fetch(payload, [:text, "text", :content, "content"]) || ""

    %{
      type: "message",
      role: "assistant",
      status: "streaming",
      content: [%{type: "output_text", text: text}]
    }
  end

  defp response_item(event, payload) when event in ["progress", "tool_result"] do
    tool = fetch(payload, [:tool, "tool"]) || "tool"
    call_id = fetch(payload, [:tool_call_id, "tool_call_id", :call_id, "call_id"]) || tool

    if event == "tool_result" do
      %{
        type: "function_call_output",
        call_id: call_id,
        status: fetch(payload, [:status, "status"]) || "complete",
        output: encode_json(fetch(payload, [:result, "result"]) || %{})
      }
    else
      %{
        type: "function_call",
        call_id: call_id,
        name: tool,
        status: fetch(payload, [:status, "status"]) || "running",
        arguments: encode_json(fetch(payload, [:input, "input", :arguments, "arguments"]) || %{})
      }
    end
  end

  defp response_item("done", payload) do
    reply = fetch(payload, [:reply, "reply", :text, "text", :message, "message"]) || ""

    %{
      type: "message",
      role: "assistant",
      status: "completed",
      content: [%{type: "output_text", text: reply}]
    }
  end

  defp response_item("error", payload) do
    %{
      type: "error",
      status: "failed",
      message: fetch(payload, [:message, "message", :error, "error"]) || "Agent failed"
    }
  end

  defp response_item(event, payload) do
    %{
      type: event,
      status: fetch(payload, [:status, "status"])
    }
  end

  defp progress_nodes(_event, payload) do
    existing =
      fetch(payload, [:progressNodes, "progressNodes", :progress_nodes, "progress_nodes"])

    cond do
      is_list(existing) ->
        existing

      activity = fetch(payload, [:activity, "activity"]) ->
        Enum.map(List.wrap(activity), &activity_node/1)

      fetch(payload, [:label, "label"]) ->
        [tool_node(payload)]

      true ->
        []
    end
  end

  defp activity_node(item) do
    item = ensure_map(item)

    %{
      id: fetch(item, [:id, "id"]) || "activity:#{fetch(item, [:title, "title"]) || "step"}",
      label: fetch(item, [:title, "title"]) || fetch(item, [:label, "label"]) || "Working",
      status: fetch(item, [:status, "status"]) || "running",
      depth: fetch(item, [:depth, "depth"]) || 0,
      kind: fetch(item, [:kind, "kind"]) || "task",
      target: fetch(item, [:detail, "detail"]) || fetch(item, [:prompt, "prompt"]),
      parentId: fetch(item, [:parentId, "parentId", :parent_id, "parent_id"]),
      subagentType: fetch(item, [:agentLabel, "agentLabel", :agent_label, "agent_label"])
    }
  end

  defp tool_node(payload) do
    tool = fetch(payload, [:tool, "tool"]) || "tool"
    label = fetch(payload, [:label, "label"]) || tool
    status = fetch(payload, [:status, "status"]) || "running"

    %{
      id:
        fetch(payload, [:activityId, "activityId", :tool_call_id, "tool_call_id"]) ||
          "tool:#{tool}",
      label: label,
      status: if(status == "complete", do: "done", else: status),
      depth: 0,
      kind: tool_kind(tool),
      target: fetch(payload, [:target, "target"]),
      tool: tool,
      callId: fetch(payload, [:tool_call_id, "tool_call_id", :call_id, "call_id"]) || tool,
      eventType: fetch(payload, [:type, "type"]) || "progress"
    }
  end

  defp tool_kind(tool) do
    tool = to_string(tool)

    cond do
      String.contains?(tool, "search") -> "web"
      String.contains?(tool, "document") -> "read"
      String.contains?(tool, "config") || String.contains?(tool, "update") -> "write"
      true -> "tool"
    end
  end

  defp terminal?(event), do: event in ["done", "error", "review_ready"]

  defp fetch(map, keys) when is_map(map), do: Enum.find_value(keys, &Map.get(map, &1))
  defp fetch(_map, _keys), do: nil

  defp ensure_map(map) when is_map(map), do: map
  defp ensure_map(_), do: %{}

  defp encode_json(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      {:error, _error} -> Jason.encode!(inspect(value))
    end
  end
end
