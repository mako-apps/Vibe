defmodule Vibe.MeshAssembler do
  @moduledoc """
  Server-side fragment reassembly for the mesh relay network.

  Receives k-of-n Shamir Secret Sharing fragments from multiple relay paths.
  When enough fragments (≥ threshold) arrive for a given set_id,
  triggers reassembly and delivers the original payload.

  Fragments are stored in ETS for fast access and auto-expire after a TTL.
  """

  use GenServer
  require Logger

  @table :mesh_fragments
  @cleanup_interval_ms 60_000
  @fragment_ttl_ms 30_000

  # ── Public API ──────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Submit a fragment. Returns {:ok, payload} if the set is now complete,
  :pending if more fragments are needed, or {:error, reason} on failure.
  """
  def submit_fragment(fragment) when is_map(fragment) do
    set_id = fragment["set_id"] || fragment[:set_id]
    threshold = fragment["threshold"] || fragment[:threshold]
    share_index = fragment["share_index"] || fragment[:share_index]
    total_shares = fragment["total_shares"] || fragment[:total_shares]
    payload_len = fragment["payload_len"] || fragment[:payload_len]
    payload_hash = fragment["payload_hash"] || fragment[:payload_hash]
    share_data = fragment["share_data"] || fragment[:share_data]

    unless set_id && threshold && share_index && share_data do
      {:error, :invalid_fragment}
    else
      entry = %{
        set_id: set_id,
        threshold: threshold,
        share_index: share_index,
        total_shares: total_shares,
        payload_len: payload_len,
        payload_hash: payload_hash,
        share_data: share_data,
        received_at: System.system_time(:millisecond)
      }

      # Store in ETS
      :ets.insert(@table, {{set_id, share_index}, entry})

      # Check if we have enough fragments to reconstruct
      all_fragments = get_set_fragments(set_id)

      if length(all_fragments) >= threshold do
        case reconstruct(all_fragments, threshold, payload_len, payload_hash) do
          {:ok, payload} ->
            # Clean up fragments for this set
            cleanup_set(set_id)
            Logger.info("[MeshAssembler] Reconstructed set #{set_id} (#{byte_size(payload)} bytes)")
            {:ok, payload}

          {:error, reason} ->
            Logger.warning("[MeshAssembler] Reconstruction failed for set #{set_id}: #{reason}")
            :pending
        end
      else
        :pending
      end
    end
  end

  @doc """
  Get stats about pending fragment sets.
  """
  def stats do
    all = :ets.tab2list(@table)
    sets = all |> Enum.map(fn {{set_id, _}, _} -> set_id end) |> Enum.uniq()
    %{
      pending_sets: length(sets),
      total_fragments: length(all)
    }
  end

  # ── GenServer Callbacks ─────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.system_time(:millisecond)
    expired =
      :ets.tab2list(@table)
      |> Enum.filter(fn {_key, entry} ->
        now - entry.received_at > @fragment_ttl_ms
      end)

    for {key, _entry} <- expired do
      :ets.delete(@table, key)
    end

    if length(expired) > 0 do
      Logger.debug("[MeshAssembler] Cleaned up #{length(expired)} expired fragments")
    end

    schedule_cleanup()
    {:noreply, state}
  end

  # ── Private ─────────────────────────────────────────────────

  defp get_set_fragments(set_id) do
    :ets.match_object(@table, {{set_id, :_}, :_})
    |> Enum.map(fn {_key, entry} -> entry end)
  end

  defp cleanup_set(set_id) do
    # Delete all fragments for this set
    fragments = :ets.match_object(@table, {{set_id, :_}, :_})
    for {key, _} <- fragments do
      :ets.delete(@table, key)
    end
  end

  defp reconstruct(fragments, threshold, expected_len, expected_hash) do
    # Sort by share_index and take the first `threshold` fragments
    sorted = Enum.sort_by(fragments, & &1.share_index) |> Enum.take(threshold)

    # Reconstruct using Lagrange interpolation over GF(257)
    field_prime = 257
    payload_len = expected_len || (hd(sorted)).payload_len

    result =
      Enum.reduce_while(0..(payload_len - 1), {:ok, <<>>}, fn offset, {:ok, acc} ->
        secret =
          Enum.reduce(sorted, 0, fn fragment, secret_acc ->
            xi = fragment.share_index
            yi = Enum.at(fragment.share_data, offset, 0)

            {numerator, denominator} =
              Enum.reduce(sorted, {1, 1}, fn other, {num, den} ->
                if other.share_index == xi do
                  {num, den}
                else
                  xj = other.share_index
                  {mod_prime(num * -xj, field_prime), mod_prime(den * (xi - xj), field_prime)}
                end
              end)

            inv = mod_inverse(denominator, field_prime)
            basis = mod_prime(numerator * inv, field_prime)
            mod_prime(secret_acc + yi * basis, field_prime)
          end)

        if secret >= 0 and secret <= 255 do
          {:cont, {:ok, acc <> <<secret::8>>}}
        else
          {:halt, {:error, "invalid byte at offset #{offset}"}}
        end
      end)

    case result do
      {:ok, payload} ->
        # Verify hash
        actual_hash = Base.encode16(:crypto.hash(:sha256, payload), case: :lower)
        if expected_hash && actual_hash != expected_hash do
          {:error, "hash mismatch"}
        else
          {:ok, payload}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp mod_prime(value, prime) do
    result = rem(value, prime)
    if result < 0, do: result + prime, else: result
  end

  defp mod_inverse(value, prime) do
    {_, _, t} = extended_gcd(mod_prime(value, prime), prime)
    mod_prime(t, prime)
  end

  defp extended_gcd(0, b), do: {b, 0, 1}
  defp extended_gcd(a, b) do
    {g, x, y} = extended_gcd(rem(b, a), a)
    {g, y - div(b, a) * x, x}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
