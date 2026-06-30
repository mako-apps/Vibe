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
  @pending_ask_table :agent_bridge_pending_asks
  @pairing_ttl_ms 10 * 60 * 1000
  @request_ttl_ms 10 * 60 * 1000
  # Mirrors the bridge's ASK_TIMEOUT_MS — an ask older than this is dead anyway.
  @pending_ask_ttl_ms 10 * 60 * 1000

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

  # ── Pending asks (ephemeral, ETS) ───────────────────────────────────
  #
  # An ask (plan approval / question) is relayed to the chat as a one-shot
  # `agent-bridge-ask` broadcast. If the phone's socket is mid-reconnect at that
  # instant the broadcast is silently dropped — and unlike streams (re-watched)
  # or results (re-delivered) there was no second chance, so the run stalls for
  # the full ASK timeout. We buffer the latest unanswered ask per chat here and
  # replay it when the phone (re)joins `chat:<id>`; it's cleared when the phone
  # answers or after the TTL.

  @doc """
  Remember the latest unanswered ask for `chat_id` so it can be replayed to a
  phone that joins `chat:<id>` after missing the live broadcast. Keyed by chat
  (the bridge serializes asks, so at most one is outstanding per chat).
  """
  def remember_pending_ask(chat_id, request_id, payload)
      when is_binary(chat_id) and chat_id != "" and is_binary(request_id) and is_map(payload) do
    ensure_table(@pending_ask_table)
    expires_at = System.system_time(:millisecond) + @pending_ask_ttl_ms

    :ets.insert(
      @pending_ask_table,
      {chat_id, %{request_id: request_id, payload: payload, expires_at: expires_at}}
    )

    :ok
  end

  def remember_pending_ask(_, _, _), do: :ok

  @doc """
  Peek the buffered ask payload for `chat_id` (or `nil` if none / expired).
  Does not consume it — a still-unanswered ask must survive repeated rejoins.
  """
  def pending_ask(chat_id) when is_binary(chat_id) and chat_id != "" do
    ensure_table(@pending_ask_table)
    now = System.system_time(:millisecond)

    case :ets.lookup(@pending_ask_table, chat_id) do
      [{^chat_id, %{expires_at: expires_at}}] when expires_at <= now ->
        :ets.delete(@pending_ask_table, chat_id)
        nil

      [{^chat_id, %{payload: payload}}] ->
        payload

      _ ->
        nil
    end
  end

  def pending_ask(_), do: nil

  @doc """
  Clear the buffered ask for `chat_id` once it has been answered. Only clears
  when `request_id` matches the buffered one (a stale response must not clobber
  a newer outstanding ask); pass `nil` to clear unconditionally.
  """
  def clear_pending_ask(chat_id, request_id) when is_binary(chat_id) and chat_id != "" do
    ensure_table(@pending_ask_table)

    case :ets.lookup(@pending_ask_table, chat_id) do
      [{^chat_id, %{request_id: ^request_id}}] ->
        :ets.delete(@pending_ask_table, chat_id)

      [{^chat_id, _}] when is_nil(request_id) ->
        :ets.delete(@pending_ask_table, chat_id)

      _ ->
        :ok
    end

    :ok
  end

  def clear_pending_ask(_, _), do: :ok

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

    case Repo.one(from(c in Connection, where: c.token_hash == ^hash and is_nil(c.revoked_at))) do
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
    Repo.exists?(from(c in Connection, where: c.user_id == ^user_id and is_nil(c.revoked_at)))
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

  @doc "Public bridge status for the phone UI, including connected devices and repo choices."
  def status(user_id) when is_binary(user_id) and user_id != "" do
    presence = VibeWeb.Presence.list(topic(user_id))
    devices = presence_devices(presence)

    repositories =
      devices
      |> Enum.flat_map(fn device -> Map.get(device, "repositories", []) end)
      |> dedupe_repositories()

    running_tasks =
      devices
      |> Enum.flat_map(fn device -> Map.get(device, "runningTasks", []) end)
      |> dedupe_running_tasks()

    %{
      connected: map_size(presence) > 0,
      paired: paired?(user_id),
      devices: devices,
      repositories: repositories,
      runningTasks: running_tasks
    }
  rescue
    _ ->
      %{
        connected: false,
        paired: paired?(user_id),
        devices: [],
        repositories: [],
        runningTasks: []
      }
  end

  def status(_),
    do: %{connected: false, paired: false, devices: [], repositories: [], runningTasks: []}

  @doc "Normalize daemon-reported status before storing it in Presence metadata."
  def presence_meta(payload) when is_map(payload) do
    %{
      "online_at" => System.system_time(:second),
      "deviceLabel" => normalize(payload["deviceLabel"] || payload["device_label"]) || "computer",
      "cwd" => normalize(payload["cwd"]),
      "repositories" => normalize_repositories(payload["repositories"]),
      "runningTasks" =>
        normalize_running_tasks(payload["runningTasks"] || payload["running_tasks"]),
      "permissions" => normalize_permissions(payload["permissions"])
    }
  end

  def presence_meta(_payload) do
    %{"online_at" => System.system_time(:second), "repositories" => []}
  end

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

  @doc """
  Push a control action to the connected bridge daemon for an in-flight task.

  The chat channel verifies chat membership before calling this; the bridge daemon
  still matches by task id/provider/chat id and refuses unknown tasks.
  """
  def dispatch_control(user_id, payload) when is_binary(user_id) and is_map(payload) do
    if online?(user_id) do
      VibeWeb.Endpoint.broadcast(topic(user_id), "control_task", payload)
      :ok
    else
      {:error, :offline}
    end
  end

  @doc """
  Ask a user's connected bridge daemon for the agent's local conversation
  history (Claude Code / Codex session logs). The daemon reads its session
  store read-only and replies with a `history_result` over the bridge channel,
  which the channel relays back to the requesting phone.
  """
  def dispatch_history(user_id, payload) when is_binary(user_id) and is_map(payload) do
    if online?(user_id) do
      VibeWeb.Endpoint.broadcast(topic(user_id), "history_request", payload)
      :ok
    else
      {:error, :offline}
    end
  end

  @doc """
  Ask a user's connected bridge daemon for the full contents of a file the agent
  touched. The daemon reads it only if the path is inside a linked repo, seals
  the bytes with the runtime key (the server stays blind), and replies with a
  `file_result` over the bridge channel, relayed back to the requesting phone.
  """
  def dispatch_file(user_id, payload) when is_binary(user_id) and is_map(payload) do
    if online?(user_id) do
      VibeWeb.Endpoint.broadcast(topic(user_id), "file_request", payload)
      :ok
    else
      {:error, :offline}
    end
  end

  @doc """
  Relay the phone's answer to a bridge-issued `ask_request` (plan approval or a
  mid-run question) back to the user's connected bridge daemon. The `answerEnc`
  blob is sealed with the pairing runtime key — the server never reads it.
  """
  def dispatch_ask_response(user_id, payload) when is_binary(user_id) and is_map(payload) do
    if online?(user_id) do
      VibeWeb.Endpoint.broadcast(topic(user_id), "ask_response", payload)
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

  defp presence_devices(presence) when is_map(presence) do
    presence
    |> Enum.flat_map(fn {_key, %{metas: metas}} -> metas || [] end)
    |> Enum.map(&public_presence_meta/1)
  end

  defp presence_devices(_), do: []

  defp public_presence_meta(meta) when is_map(meta) do
    %{
      "online_at" => meta["online_at"] || meta[:online_at],
      "deviceLabel" =>
        meta["deviceLabel"] || meta[:deviceLabel] || meta["device_label"] || "computer",
      "cwd" => meta["cwd"] || meta[:cwd],
      "repositories" => normalize_repositories(meta["repositories"] || meta[:repositories]),
      "runningTasks" =>
        normalize_running_tasks(
          meta["runningTasks"] || meta[:runningTasks] || meta["running_tasks"]
        ),
      "permissions" => normalize_permissions(meta["permissions"] || meta[:permissions])
    }
  end

  defp public_presence_meta(_), do: %{"repositories" => []}

  defp normalize_repositories(values) when is_list(values) do
    values
    |> Enum.map(&normalize_repository/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_repositories(_), do: []

  defp normalize_running_tasks(values) when is_list(values) do
    values
    |> Enum.map(&normalize_running_task/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_running_tasks(_), do: []

  defp normalize_running_task(task) when is_map(task) do
    task_id = normalize(task["taskId"] || task[:taskId] || task["task_id"] || task[:task_id])

    if is_nil(task_id) do
      nil
    else
      %{
        "provider" => normalize(task["provider"] || task[:provider]),
        "chatId" =>
          normalize(task["chatId"] || task[:chatId] || task["chat_id"] || task[:chat_id]),
        "taskId" => task_id,
        "sessionId" =>
          normalize(
            task["sessionId"] || task[:sessionId] || task["session_id"] || task[:session_id]
          ),
        "topic" => normalize(task["topic"] || task[:topic]) || "Running task",
        "repoId" =>
          normalize(task["repoId"] || task[:repoId] || task["repo_id"] || task[:repo_id]),
        "repoName" =>
          normalize(task["repoName"] || task[:repoName] || task["repo_name"] || task[:repo_name]),
        "project" => normalize(task["project"] || task[:project] || task["cwd"] || task[:cwd]),
        "projectName" =>
          normalize(
            task["projectName"] || task[:projectName] || task["project_name"] ||
              task[:project_name]
          ),
        "cwd" => normalize(task["cwd"] || task[:cwd]),
        "workMode" =>
          normalize(task["workMode"] || task[:workMode] || task["work_mode"] || task[:work_mode]),
        "startedAt" =>
          normalize(
            task["startedAt"] || task[:startedAt] || task["started_at"] || task[:started_at]
          ),
        "durationMs" =>
          task["durationMs"] || task[:durationMs] || task["duration_ms"] || task[:duration_ms],
        "command" => normalize(task["command"] || task[:command]),
        "pendingCommand" =>
          normalize(
            task["pendingCommand"] || task[:pendingCommand] || task["pending_command"] ||
              task[:pending_command]
          ),
        "teamMode" =>
          normalize(task["teamMode"] || task[:teamMode] || task["team_mode"] || task[:team_mode]),
        "teamRunId" =>
          normalize(
            task["teamRunId"] || task[:teamRunId] || task["team_run_id"] || task[:team_run_id]
          ),
        "teamWorker" =>
          normalize(
            task["teamWorker"] || task[:teamWorker] || task["team_worker"] ||
              task[:team_worker]
          ),
        "teamWorkers" =>
          normalize_string_list(
            task["teamWorkers"] || task[:teamWorkers] || task["team_workers"] ||
              task[:team_workers]
          )
      }
    end
  end

  defp normalize_running_task(_), do: nil

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.map(&normalize/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_string_list(_), do: []

  defp normalize_repository(repo) when is_map(repo) do
    path = normalize(repo["path"] || repo[:path] || repo["cwd"] || repo[:cwd])
    id = normalize(repo["id"] || repo[:id])

    cond do
      is_nil(path) ->
        nil

      true ->
        %{
          "id" => id || repo_id(path),
          "name" => normalize(repo["name"] || repo[:name]) || Path.basename(path),
          "path" => path,
          "cwd" => normalize(repo["cwd"] || repo[:cwd]) || path,
          "source" => normalize(repo["source"] || repo[:source]) || "bridge",
          "git" => truthy?(repo["git"] || repo[:git])
        }
    end
  end

  defp normalize_repository(_), do: nil

  defp repo_id(path) do
    :crypto.hash(:sha256, path)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 16)
  end

  defp dedupe_repositories(repositories) do
    repositories
    |> Enum.reduce({MapSet.new(), []}, fn repo, {seen, acc} ->
      key = repo["id"] || repo["path"]

      if is_binary(key) and not MapSet.member?(seen, key) do
        {MapSet.put(seen, key), [repo | acc]}
      else
        {seen, acc}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp dedupe_running_tasks(tasks) do
    tasks
    |> Enum.reduce({MapSet.new(), []}, fn task, {seen, acc} ->
      key = task["taskId"] || task["sessionId"]

      if is_binary(key) and not MapSet.member?(seen, key) do
        {MapSet.put(seen, key), [task | acc]}
      else
        {seen, acc}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp normalize_permissions(value) when is_map(value), do: value
  defp normalize_permissions(_), do: %{}

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_), do: false
end
