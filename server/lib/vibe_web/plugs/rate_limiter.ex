defmodule VibeWeb.Plugs.RateLimiter do
  @moduledoc """
  Rate limiting plug to prevent brute force attacks.
  Uses ETS for in-memory rate limiting (resets on server restart).

  For production, consider using Redis-based rate limiting for distributed environments.
  """
  import Plug.Conn

  @behaviour Plug

  # Default limits (can be overridden in opts)
  @default_limits %{
    auth: {5, 60_000},      # 5 attempts per minute for login/register
    api: {100, 60_000},     # 100 requests per minute for general API
    strict: {3, 300_000}    # 3 attempts per 5 minutes for sensitive ops
  }

  def init(opts) do
    # Ensure ETS table exists
    ensure_table_exists()
    opts
  end

  def call(conn, opts) do
    # Ensure table exists at runtime (defensive check)
    ensure_table_exists()

    limit_type = Keyword.get(opts, :type, :api)
    {max_requests, window_ms} = Map.get(@default_limits, limit_type, {100, 60_000})

    # Use IP address as identifier (or user_id if authenticated)
    identifier = get_identifier(conn)
    key = {limit_type, identifier}

    case check_rate_limit(key, max_requests, window_ms) do
      :ok ->
        conn

      {:error, retry_after_ms} ->
        retry_after_seconds = div(retry_after_ms, 1000) + 1

        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after_seconds))
        |> put_resp_header("x-ratelimit-limit", Integer.to_string(max_requests))
        |> put_resp_header("x-ratelimit-remaining", "0")
        |> put_resp_content_type("application/json")
        |> send_resp(429, Jason.encode!(%{
          error: "Too many requests",
          retry_after: retry_after_seconds,
          message: "Please slow down. Try again in #{retry_after_seconds} seconds."
        }))
        |> halt()
    end
  end

  defp get_identifier(conn) do
    # Try to get real IP from X-Forwarded-For (behind proxy/load balancer)
    forwarded_for = get_req_header(conn, "x-forwarded-for") |> List.first()

    ip = if forwarded_for do
      forwarded_for |> String.split(",") |> List.first() |> String.trim()
    else
      conn.remote_ip |> :inet.ntoa() |> to_string()
    end

    ip
  end

  defp ensure_table_exists do
    case :ets.whereis(:rate_limiter) do
      :undefined ->
        :ets.new(:rate_limiter, [:set, :public, :named_table, {:read_concurrency, true}])
      _ ->
        :ok
    end
  end

  defp check_rate_limit(key, max_requests, window_ms) do
    now = System.system_time(:millisecond)
    window_start = now - window_ms

    case :ets.lookup(:rate_limiter, key) do
      [] ->
        # First request - allow and record
        :ets.insert(:rate_limiter, {key, [{now, 1}]})
        :ok

      [{^key, requests}] ->
        # Filter out old requests outside the window
        recent_requests = Enum.filter(requests, fn {timestamp, _} -> timestamp > window_start end)
        total_count = Enum.reduce(recent_requests, 0, fn {_, count}, acc -> acc + count end)

        if total_count >= max_requests do
          # Rate limited - calculate retry-after
          oldest_in_window = recent_requests |> Enum.map(fn {ts, _} -> ts end) |> Enum.min(fn -> now end)
          retry_after = oldest_in_window + window_ms - now
          {:error, max(retry_after, 1000)}
        else
          # Allow and record
          new_requests = [{now, 1} | recent_requests] |> Enum.take(max_requests * 2)
          :ets.insert(:rate_limiter, {key, new_requests})
          :ok
        end
    end
  end
end
