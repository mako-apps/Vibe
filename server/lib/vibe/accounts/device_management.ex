defmodule Vibe.Accounts.DeviceManagement do
  @moduledoc """
  Multi-account device sessions, device linking/pairing, and per-account
  notification preferences.

  Secret keys never transit or persist server-side: linking only ever stores
  a `wrapped_key_envelope` opaque blob produced client-side (the requester's
  public key wraps the approver's key material off-box). Session tokens and
  pairing codes are stored only as SHA-256 hashes, matching the pattern
  already used for `users.login_token`.
  """

  import Ecto.Query, warn: false

  alias Vibe.Repo
  alias Vibe.Schemas.AccountDevice
  alias Vibe.Schemas.DeviceSession
  alias Vibe.Schemas.DeviceLinkRequest
  alias Vibe.Schemas.NotificationPreference

  @session_validity_seconds 30 * 24 * 60 * 60
  @link_request_validity_seconds 5 * 60

  # -- Devices ---------------------------------------------------------

  @doc "Registers or refreshes the calling device and returns {:ok, account_device}."
  def register_device(user_id, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case Repo.get_by(AccountDevice,
           user_id: user_id,
           device_identifier: attrs["device_identifier"] || attrs[:device_identifier]
         ) do
      nil ->
        %AccountDevice{}
        |> AccountDevice.changeset(Map.merge(attrs, %{"user_id" => user_id, "last_seen_at" => now}))
        |> Repo.insert()

      existing ->
        existing
        |> AccountDevice.changeset(Map.merge(attrs, %{"last_seen_at" => now, "revoked_at" => nil}))
        |> Repo.update()
    end
  end

  @doc "Lists non-revoked devices for a user, most recently seen first."
  def list_devices(user_id) do
    AccountDevice
    |> where([d], d.user_id == ^user_id and is_nil(d.revoked_at))
    |> order_by([d], desc: d.last_seen_at)
    |> Repo.all()
  end

  @doc "Revokes a device and cascades revocation to its active sessions."
  def revoke_device(user_id, device_id) do
    with %AccountDevice{} = device <- Repo.get_by(AccountDevice, id: device_id, user_id: user_id) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.transaction(fn ->
        {:ok, device} =
          device
          |> AccountDevice.changeset(%{"revoked_at" => now})
          |> Repo.update()

        {_count, _} =
          DeviceSession
          |> where([s], s.account_device_id == ^device_id and is_nil(s.revoked_at))
          |> Repo.update_all(set: [revoked_at: now])

        device
      end)
    else
      nil -> {:error, :not_found}
    end
  end

  # -- Device sessions ---------------------------------------------------

  @doc "Issues a device-scoped session token; returns {:ok, plaintext_token, session}."
  def create_device_session(user_id, account_device_id) do
    token = generate_token()
    token_hash = hash_token(token)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    expires_at = DateTime.add(now, @session_validity_seconds, :second)

    case %DeviceSession{}
         |> DeviceSession.changeset(%{
           user_id: user_id,
           account_device_id: account_device_id,
           token_hash: token_hash,
           expires_at: expires_at
         })
         |> Repo.insert() do
      {:ok, session} -> {:ok, token, session}
      error -> error
    end
  end

  @doc "Resolves a bearer token to its live session, sliding expiry on use."
  def get_session_by_token(token) do
    token_hash = hash_token(token)

    case Repo.get_by(DeviceSession, token_hash: token_hash) do
      nil ->
        {:error, :not_found}

      %DeviceSession{revoked_at: revoked_at} when not is_nil(revoked_at) ->
        {:error, :revoked}

      %DeviceSession{expires_at: expires_at} = session ->
        now = DateTime.utc_now()

        if DateTime.compare(expires_at, now) == :lt do
          {:error, :expired}
        else
          {:ok, touch_session(session, now)}
        end
    end
  end

  defp touch_session(session, now) do
    truncated = DateTime.truncate(now, :second)

    session
    |> DeviceSession.changeset(%{last_used_at: truncated})
    |> Repo.update()
    |> case do
      {:ok, updated} -> updated
      _ -> session
    end
  end

  @doc "Revokes a single device session (e.g. explicit sign-out)."
  def revoke_session(user_id, session_id) do
    case Repo.get_by(DeviceSession, id: session_id, user_id: user_id) do
      nil ->
        {:error, :not_found}

      session ->
        session
        |> DeviceSession.changeset(%{revoked_at: DateTime.utc_now() |> DateTime.truncate(:second)})
        |> Repo.update()
    end
  end

  # -- Device linking / pairing ------------------------------------------

  @doc """
  Starts a pairing request from a not-yet-authenticated requester device.
  Returns {:ok, plaintext_code, request}. The code is single-use and expires
  after #{@link_request_validity_seconds}s.
  """
  def start_link_request(attrs) do
    code = generate_pairing_code()
    code_hash = hash_token(code)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    expires_at = DateTime.add(now, @link_request_validity_seconds, :second)

    case %DeviceLinkRequest{}
         |> DeviceLinkRequest.changeset(Map.merge(attrs, %{
           "code_hash" => code_hash,
           "expires_at" => expires_at
         }))
         |> Repo.insert() do
      {:ok, request} -> {:ok, code, request}
      error -> error
    end
  end

  @doc "Looks up a pending, unexpired link request by its plaintext code."
  def get_pending_link_request(code) do
    code_hash = hash_token(code)

    case Repo.get_by(DeviceLinkRequest, code_hash: code_hash) do
      nil ->
        {:error, :not_found}

      %DeviceLinkRequest{consumed_at: c} when not is_nil(c) ->
        {:error, :consumed}

      %DeviceLinkRequest{rejected_at: r} when not is_nil(r) ->
        {:error, :rejected}

      %DeviceLinkRequest{expires_at: expires_at} = request ->
        if DateTime.compare(expires_at, DateTime.utc_now()) == :lt do
          {:error, :expired}
        else
          {:ok, request}
        end
    end
  end

  @doc """
  Approves a pending link request from the already-authenticated owning
  account. `wrapped_key_envelope` must already be wrapped client-side for the
  requester's public key; the server never sees plaintext key material.
  """
  def approve_link_request(user_id, code, wrapped_key_envelope) do
    with {:ok, request} <- get_pending_link_request(code) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      request
      |> DeviceLinkRequest.approve_changeset(%{
        user_id: user_id,
        wrapped_key_envelope: wrapped_key_envelope,
        approved_at: now
      })
      |> Repo.update()
    end
  end

  def reject_link_request(code) do
    with {:ok, request} <- get_pending_link_request(code) do
      request
      |> DeviceLinkRequest.changeset(%{rejected_at: DateTime.utc_now() |> DateTime.truncate(:second)})
      |> Repo.update()
    end
  end

  @doc """
  Consumes an approved link request exactly once: registers the requester's
  device, mints its session token, and returns the wrapped key envelope for
  the requester to unwrap locally.
  """
  def claim_link_request(code) do
    with {:ok, request} <- get_pending_link_request(code) do
      cond do
        is_nil(request.approved_at) ->
          {:error, :not_approved}

        is_nil(request.user_id) or is_nil(request.wrapped_key_envelope) ->
          {:error, :not_approved}

        true ->
          Repo.transaction(fn ->
            now = DateTime.utc_now() |> DateTime.truncate(:second)

            {:ok, device} =
              register_device(request.user_id, %{
                "device_identifier" => request.requester_device_identifier,
                "name" => request.requester_name,
                "platform" => request.requester_platform,
                "public_key" => request.requester_public_key
              })

            {:ok, token, session} = create_device_session(request.user_id, device.id)

            {:ok, _request} =
              request
              |> DeviceLinkRequest.changeset(%{consumed_at: now})
              |> Repo.update()

            %{
              user_id: request.user_id,
              device: device,
              session: session,
              session_token: token,
              wrapped_key_envelope: request.wrapped_key_envelope
            }
          end)
      end
    end
  end

  # -- Notification preferences -------------------------------------------

  @doc "Fetches (or lazily creates with defaults) a user's notification preferences."
  def get_notification_preferences(user_id) do
    case Repo.get_by(NotificationPreference, user_id: user_id) do
      nil ->
        %NotificationPreference{}
        |> NotificationPreference.changeset(%{
          user_id: user_id,
          preferences: NotificationPreference.default_preferences()
        })
        |> Repo.insert()
        |> case do
          {:ok, pref} -> pref
          {:error, _} -> Repo.get_by(NotificationPreference, user_id: user_id)
        end

      pref ->
        pref
    end
  end

  @doc "Deep-merges the given preference updates over defaults/current state."
  def update_notification_preferences(user_id, updates) when is_map(updates) do
    current = get_notification_preferences(user_id)
    merged = deep_merge(current.preferences, stringify_keys(updates))

    current
    |> NotificationPreference.changeset(%{preferences: merged})
    |> Repo.update()
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, l, r ->
      if is_map(l) and is_map(r), do: deep_merge(l, r), else: r
    end)
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      {to_string(k), if(is_map(v), do: stringify_keys(v), else: v)}
    end)
  end

  # -- Token helpers -------------------------------------------------------

  defp generate_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp generate_pairing_code do
    :crypto.strong_rand_bytes(6) |> Base.encode32(case: :upper, padding: false)
  end

  defp hash_token(token) do
    :crypto.hash(:sha256, token)
  end
end
