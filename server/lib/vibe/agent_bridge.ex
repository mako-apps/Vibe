defmodule Vibe.AgentBridge do
  @moduledoc """
  Pairing + token management for the **agent bridge** — the small daemon a user
  runs on their OWN computer so `@claude` / `@codex` execute locally (using their
  own subscription) and stream results back into Vibe chats.

  Two credentials, modelled on the OAuth 2.0 Device Authorization Grant (RFC 8628):

    * `pairing_code` — short-lived (10 min), single-use. Minted by the
      authenticated phone and shown as a QR / one-line install command. Held in
      ETS only.
    * `bridge_token` — long-lived, minted when the daemon redeems a `pairing_code`.
      Bound to the user, stored **hashed** in `agent_bridge_connections`, and
      revocable from the app.

  Online status (is a paired computer connected right now?) is tracked via
  `VibeWeb.Presence` on the `bridge:<user_id>` topic — see `online?/1`.
  """

  require Logger
  import Ecto.Query
  alias Vibe.Repo
  alias Vibe.AgentBridge.Connection

  @pairing_table :agent_bridge_pairings
  @request_table :agent_bridge_requests
  @pairing_ttl_ms 10 * 60 * 1000
  @request_ttl_ms 10 * 60 * 1000

  # ── Scan-to-pair (daemon-initiated; the phone scans the desktop QR) ──

  @doc """
  Create a pairing request initiated by the daemon (desktop). Returns a public
  `request_id` (encoded into the QR the desktop shows) plus a private
  `device_secret` the daemon keeps to later claim its token. The authenticated
  phone scans the QR and calls `authorize_request/2`; the daemon then redeems
  the parked token with `claim_request/2`.
  """
  def create_request(device_label \\ "computer") do
    ensure_table(@request_table)
    request_id = generate_token(18)
    device_secret = generate_token(24)
    expires_at = System.system_time(:millisecond) + @request_ttl_ms

    :ets.insert(
      @request_table,
      {request_id,
       %{
         device_hash: hash_token(device_secret),
         device_label: normalize(device_label) || "computer",
         status: :pending,
         user_id: nil,
         bridge_token: nil,
         expires_at: expires_at
       }}
    )

    %{
      request_id: request_id,
      device_secret: device_secret,
      expires_in: div(@request_ttl_ms, 1000)
    }
  end

  @doc """
  Authorize a pending request for `user_id` — called by the authenticated phone
  right after it scans the QR. Mints the bridge token now and parks it (in ETS)
  for the daemon to claim.
  """
  def authorize_request(request_id, user_id)
      when is_binary(request_id) and is_binary(user_id) and user_id != "" do
    ensure_table(@request_table)
    now = System.system_time(:millisecond)

    case :ets.lookup(@request_table, request_id) do
      [{^request_id, %{status: :pending, expires_at: exp} = req}] when exp > now ->
        case mint_token(user_id, req.device_label) do
          {:ok, %{bridge_token: token}} ->
            :ets.insert(
              @request_table,
              {request_id, %{req | status: :authorized, user_id: user_id, bridge_token: token}}
            )

            :ok

          {:error, _} = err ->
            err
        end

      [{^request_id, %{status: :authorized}}] ->
        {:error, :already_authorized}

      [{^request_id, _expired}] ->
        :ets.delete(@request_table, request_id)
        {:error, :expired}

      _ ->
        {:error, :invalid_request}
    end
  end

  def authorize_request(_, _), do: {:error, :invalid_request}

  @doc """
  Claim the parked bridge token for an authorized request — called by the daemon,
  proving ownership with its `device_secret`. Single use.
  """
  def claim_request(request_id, device_secret)
      when is_binary(request_id) and is_binary(device_secret) do
    ensure_table(@request_table)
    now = System.system_time(:millisecond)

    case :ets.lookup(@request_table, request_id) do
      [{^request_id, %{expires_at: exp}}] when exp <= now ->
        :ets.delete(@request_table, request_id)
        {:error, :expired}

      [{^request_id, %{status: :authorized, device_hash: dh, user_id: uid, bridge_token: token}}] ->
        if Plug.Crypto.secure_compare(hash_token(device_secret), dh) do
          :ets.delete(@request_table, request_id)
          {:ok, %{user_id: uid, bridge_token: token}}
        else
          {:error, :invalid}
        end

      [{^request_id, %{status: :pending}}] ->
        {:error, :pending}

      _ ->
        {:error, :invalid_request}
    end
  end

  def claim_request(_, _), do: {:error, :invalid_request}

  # ── Pairing codes (ephemeral, ETS) ──────────────────────────────────

  @doc """
  Mint a single-use pairing code for `user_id`. Returns the code and its TTL; the
  app composes the QR / install command from its known server URL.
  """
  def request_pairing(user_id) when is_binary(user_id) and user_id != "" do
    ensure_table(@pairing_table)
    code = generate_pairing_code()
    expires_at = System.system_time(:millisecond) + @pairing_ttl_ms
    :ets.insert(@pairing_table, {code, %{user_id: user_id, expires_at: expires_at}})

    %{pairing_code: code, expires_in: div(@pairing_ttl_ms, 1000)}
  end

  @doc """
  Redeem a pairing code (called by the daemon). Consumes the code (single use) and
  mints a long-lived bridge token bound to the code's user.
  """
  def redeem_pairing(code, device_label \\ "computer") when is_binary(code) do
    ensure_table(@pairing_table)
    now = System.system_time(:millisecond)

    case :ets.lookup(@pairing_table, code) do
      [{^code, %{user_id: user_id, expires_at: expires_at}}] when expires_at > now ->
        # Single use — delete immediately whether or not minting succeeds.
        :ets.delete(@pairing_table, code)
        mint_token(user_id, device_label)

      [{^code, _expired}] ->
        :ets.delete(@pairing_table, code)
        {:error, :expired}

      _ ->
        {:error, :invalid_code}
    end
  end

  # ── Bridge tokens (persistent, hashed) ──────────────────────────────

  defp mint_token(user_id, device_label) do
    raw = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %Connection{}
    |> Connection.changeset(%{
      user_id: user_id,
      token_hash: hash_token(raw),
      device_label: normalize(device_label) || "computer",
      last_seen_at: now
    })
    |> Repo.insert()
    |> case do
      {:ok, _connection} -> {:ok, %{user_id: user_id, bridge_token: raw}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc "Resolve a bridge token to its user id, or `:error`. Updates last_seen_at."
  def verify_token(token) when is_binary(token) and token != "" do
    hash = hash_token(token)

    case Repo.one(from c in Connection, where: c.token_hash == ^hash and is_nil(c.revoked_at)) do
      %Connection{} = connection ->
        touch(connection)
        {:ok, to_string(connection.user_id)}

      _ ->
        :error
    end
  end

  def verify_token(_), do: :error

  @doc "Revoke all active bridge tokens for a user (\"disconnect computer\")."
  def revoke_all(user_id) when is_binary(user_id) and user_id != "" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      Repo.update_all(
        from(c in Connection, where: c.user_id == ^user_id and is_nil(c.revoked_at)),
        set: [revoked_at: now, updated_at: now]
      )

    {:ok, count}
  end

  def revoke_all(_), do: {:ok, 0}

  @doc "Whether the user has any non-revoked paired computer on record."
  def paired?(user_id) when is_binary(user_id) do
    Repo.exists?(from c in Connection, where: c.user_id == ^user_id and is_nil(c.revoked_at))
  end

  def paired?(_), do: false

  defp touch(%Connection{} = connection) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    connection
    |> Ecto.Changeset.change(last_seen_at: now)
    |> Repo.update()
  rescue
    _ -> :ok
  end

  # ── Online status (Presence) ────────────────────────────────────────

  @doc "Is a paired computer connected to the bridge channel right now?"
  def online?(user_id) when is_binary(user_id) and user_id != "" do
    map_size(VibeWeb.Presence.list("bridge:#{user_id}")) > 0
  rescue
    _ -> false
  end

  def online?(_), do: false

  @doc "The bridge channel topic for a user."
  def topic(user_id), do: "bridge:#{user_id}"

  @doc """
  Push a task to a user's connected bridge daemon. Returns `:ok` if a bridge is
  online and the task was dispatched, `{:error, :offline}` otherwise.
  """
  def dispatch_task(user_id, payload) when is_binary(user_id) and is_map(payload) do
    if online?(user_id) do
      VibeWeb.Endpoint.broadcast(topic(user_id), "run_task", payload)
      :ok
    else
      {:error, :offline}
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp hash_token(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  defp generate_pairing_code do
    :crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false)
  end

  defp generate_token(bytes) do
    :crypto.strong_rand_bytes(bytes) |> Base.url_encode64(padding: false)
  end

  defp ensure_table(table) do
    case :ets.whereis(table) do
      :undefined ->
        :ets.new(table, [:set, :public, :named_table, {:read_concurrency, true}])
        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp normalize(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize(_), do: nil
end
