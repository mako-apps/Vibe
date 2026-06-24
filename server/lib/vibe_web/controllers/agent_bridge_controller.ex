defmodule VibeWeb.AgentBridgeController do
  @moduledoc """
  REST endpoints for pairing a user's computer (the agent bridge daemon).

  Phone-authenticated:
    * `POST   /api/agent-bridge/pairing` — mint a single-use pairing code (QR).
    * `GET    /api/agent-bridge/status`  — is a paired computer connected now?
    * `DELETE /api/agent-bridge`         — revoke all paired computers.

  Daemon (no user auth — carries only the pairing code):
    * `POST   /api/agent-bridge/pair`    — redeem a code for a long-lived token.
  """
  use VibeWeb, :controller
  require Logger

  alias Vibe.AgentBridge

  # POST /api/agent-bridge/pairing  (authenticated phone)
  def request_pairing(conn, _params) do
    user_id = conn.assigns.current_user.id
    result = AgentBridge.request_pairing(user_id)
    json(conn, result)
  end

  # POST /api/agent-bridge/pair  (daemon — body: %{"pairing_code" => ..., "device_label" => ...})
  def pair(conn, params) do
    code = params["pairing_code"] || params["code"] || ""
    device_label = params["device_label"] || params["device"] || "computer"

    case AgentBridge.redeem_pairing(code, device_label) do
      {:ok, %{user_id: user_id, bridge_token: token}} ->
        Logger.info("[AgentBridge] paired computer for user=#{user_id} device=#{device_label}")
        json(conn, %{bridge_token: token, user_id: user_id})

      {:error, :invalid_code} ->
        conn |> put_status(:bad_request) |> json(%{error: "invalid_code"})

      {:error, :expired} ->
        conn |> put_status(:bad_request) |> json(%{error: "expired"})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  # GET /api/agent-bridge/status  (authenticated phone)
  def status(conn, _params) do
    user_id = conn.assigns.current_user.id

    json(conn, %{
      connected: AgentBridge.online?(user_id),
      paired: AgentBridge.paired?(user_id)
    })
  end

  # DELETE /api/agent-bridge  (authenticated phone)
  def revoke(conn, _params) do
    user_id = conn.assigns.current_user.id
    {:ok, count} = AgentBridge.revoke_all(user_id)
    json(conn, %{revoked: count})
  end
end
