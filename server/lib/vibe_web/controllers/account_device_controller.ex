defmodule VibeWeb.AccountDeviceController do
  use VibeWeb, :controller

  alias Vibe.Accounts.DeviceManagement

  # GET /api/account/devices
  def index(conn, _params) do
    user_id = conn.assigns.current_user.id
    devices = DeviceManagement.list_devices(user_id)
    json(conn, %{devices: Enum.map(devices, &device_json/1)})
  end

  # DELETE /api/account/devices/:id
  def delete(conn, %{"id" => device_id}) do
    user_id = conn.assigns.current_user.id

    case DeviceManagement.revoke_device(user_id, device_id) do
      {:ok, device} ->
        json(conn, %{device: device_json(device)})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "Device not found"})
    end
  end

  # POST /api/account/devices/pairing
  # Unauthenticated: the requester device (e.g. new phone/desktop) starts a
  # code-scoped pairing request before it has any account session.
  def start_pairing(conn, params) do
    attrs = %{
      "requester_device_identifier" => params["requesterDeviceId"],
      "requester_name" => params["requesterName"],
      "requester_platform" => params["platform"],
      "requester_public_key" => params["requesterPublicKey"]
    }

    case DeviceManagement.start_link_request(attrs) do
      {:ok, code, request} ->
        conn
        |> put_status(:created)
        |> json(%{code: code, expiresAt: request.expires_at})

      {:error, changeset} ->
        conn |> put_status(422) |> json(%{error: "Invalid pairing request", details: changeset_errors(changeset)})
    end
  end

  # POST /api/account/devices/pairing/:code/approve
  # Authenticated: the already-linked account approves a pending request by
  # supplying a client-wrapped key envelope for the requester's public key.
  def approve_pairing(conn, %{"code" => code} = params) do
    user_id = conn.assigns.current_user.id
    wrapped_key_envelope = params["wrappedKeyEnvelope"]

    case DeviceManagement.approve_link_request(user_id, code, wrapped_key_envelope) do
      {:ok, _request} ->
        json(conn, %{success: true})

      {:error, reason} when is_atom(reason) ->
        conn |> put_status(410) |> json(%{error: to_string(reason)})

      {:error, changeset} ->
        conn |> put_status(422) |> json(%{error: "Invalid approval", details: changeset_errors(changeset)})
    end
  end

  # POST /api/account/devices/pairing/:code/claim
  # Unauthenticated: the requester device redeems an approved code exactly
  # once for its own device session token + wrapped key envelope.
  def claim_pairing(conn, %{"code" => code}) do
    case DeviceManagement.claim_link_request(code) do
      {:ok, %{user_id: user_id, device: device, session_token: token, wrapped_key_envelope: envelope}} ->
        json(conn, %{
          userId: user_id,
          device: device_json(device),
          sessionToken: token,
          wrappedKeyEnvelope: envelope
        })

      {:error, reason} when is_atom(reason) ->
        conn |> put_status(410) |> json(%{error: to_string(reason)})
    end
  end

  defp device_json(device) do
    %{
      id: device.id,
      name: device.name,
      platform: device.platform,
      lastSeenAt: device.last_seen_at,
      isRevoked: not is_nil(device.revoked_at)
    }
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
