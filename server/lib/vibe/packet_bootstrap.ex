defmodule Vibe.PacketBootstrap do
  @moduledoc """
  Issues short-lived Packet transport bootstrap payloads for authenticated Vibe users.
  """

  @ticket_ttl_secs 300
  @descriptor_ttl_secs 900

  def issue_for_user(user) do
    with {:ok, signing_secret} <- signing_secret(),
         {:ok, server_url} <- packet_server_url() do
      now = System.system_time(:second)
      bridge_id = "packet-bridge-primary"
      descriptor = build_descriptor(server_url, bridge_id, signing_secret, now)
      ticket = build_ticket(user, bridge_id, signing_secret, now)

      {:ok,
       %{
         transportMode: "packet_mesh",
         packetStatus: "bootstrap_ready",
         packetTicket: ticket,
         packetProxyHost: "127.0.0.1",
         activePacketBridgeId: bridge_id,
         packetBridgeBundle: %{
           version: 1,
           generatedAt: now * 1_000,
           expiresAt: (now + @descriptor_ttl_secs) * 1_000,
           descriptors: [descriptor]
         }
       }}
    end
  end

  defp build_ticket(user, bridge_id, signing_secret, now) do
    claims = %{
      sub: to_string(user.id),
      iat: now,
      exp: now + @ticket_ttl_secs,
      jti: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
      session_key: Base.encode64(:crypto.strong_rand_bytes(32)),
      bridge_id: bridge_id,
      capabilities: ["mesh_client"]
    }

    payload = Jason.encode!(claims) |> Base.encode64()
    signature = sign_value(payload, signing_secret)
    payload <> "." <> signature
  end

  defp build_descriptor(server_url, bridge_id, signing_secret, now) do
    pins =
      System.get_env("VIBE_PACKET_SPKI_PINS", "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    descriptor = %{
      id: bridge_id,
      baseUrl: String.trim_trailing(server_url, "/"),
      priority: 10,
      expiresAt: (now + @descriptor_ttl_secs) * 1_000,
      spkiPins: pins,
      capabilities: ["phoenix_socket", "api_http", "text_only_v1"]
    }

    Map.put(descriptor, :signature, sign_value(Jason.encode!(descriptor), signing_secret))
  end

  defp sign_value(value, signing_secret) do
    :crypto.mac(:hmac, :sha256, signing_secret, value)
    |> Base.encode16(case: :lower)
  end

  defp packet_server_url do
    value =
      System.get_env("VIBE_PACKET_SERVER_URL") ||
        System.get_env("PHANTOM_SERVER_URL") ||
        Application.get_env(:vibe, :packet_server_url)

    case normalize_string(value) do
      nil -> {:error, :packet_server_url_missing}
      url -> {:ok, url}
    end
  end

  defp signing_secret do
    value =
      System.get_env("VIBE_PACKET_SIGNING_SECRET") ||
        System.get_env("PHANTOM_SECRET") ||
        Application.get_env(:vibe, :packet_signing_secret)

    case normalize_string(value) do
      nil -> {:error, :packet_signing_secret_missing}
      secret -> {:ok, secret}
    end
  end

  defp normalize_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_string(_value), do: nil
end
