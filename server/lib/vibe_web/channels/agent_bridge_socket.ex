defmodule VibeWeb.AgentBridgeSocket do
  @moduledoc """
  Socket for the agent bridge daemon running on a user's computer. Authenticated by
  the long-lived `bridge_token` minted during pairing (NOT a user login token).
  """
  use Phoenix.Socket

  channel "bridge:*", VibeWeb.AgentBridgeChannel

  @impl true
  def connect(params, socket, connect_info) do
    token = extract_bearer(connect_info) || params["token"]

    case token && Vibe.AgentBridge.verify_connection(token) do
      {:ok, identity} ->
        {:ok,
         socket
         |> assign(:user_id, identity.user_id)
         |> assign(:computer_id, identity.computer_id)
         |> assign(:device_label, identity.device_label)}

      _ -> :error
    end
  end

  defp extract_bearer(%{x_headers: headers}) when is_list(headers) do
    Enum.find_value(headers, fn
      {"authorization", "Bearer " <> token} -> String.trim(token)
      _ -> nil
    end)
  end

  defp extract_bearer(_), do: nil

  @impl true
  def id(socket),
    do: "agent_bridge_socket:#{socket.assigns.user_id}:#{socket.assigns.computer_id}"
end
