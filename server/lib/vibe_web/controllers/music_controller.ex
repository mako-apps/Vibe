defmodule VibeWeb.MusicController do
  @moduledoc """
  Music streaming controller.

  Proxies audio from YouTube via backend for:
  - Faster streaming (no CDN throttling)
  - Caching on Supabase Storage for permanent storage
  - Lower latency for mobile clients via Supabase CDN
  """
  use VibeWeb, :controller

  require Logger

  alias Vibe.AI.Tools.YtDlp
  alias Vibe.MusicCache
  alias Vibe.SupabaseStorage
  alias Vibe.Repo
  import Ecto.Query

  # Temp directory for downloads before uploading to Supabase
  @temp_dir "/tmp/vibe_audio_downloads"

  @doc """
  Stream audio for a given video_id.
  Returns the Supabase CDN URL for cached files, or downloads fresh.

  GET /api/music/stream/:video_id
  """
  def stream(conn, %{"video_id" => video_id}) do
    Logger.info("[MusicController] Stream request for: #{video_id}")

    # Check database for cached Supabase URL
    case get_cached_url(video_id) do
      {:ok, url} ->
        Logger.info("[MusicController] Redirecting to cached: #{video_id}")
        # Redirect to Supabase CDN URL for fast delivery
        redirect(conn, external: url)

      :not_cached ->
        # Download to temp, upload to Supabase, return URL
        case download_and_upload(video_id) do
          {:ok, url} ->
            Logger.info("[MusicController] Cached and redirecting: #{video_id}")
            redirect(conn, external: url)

          {:error, reason} ->
            Logger.error("[MusicController] Download failed: #{reason}")
            conn
            |> put_status(500)
            |> json(%{error: "Failed to stream audio", reason: reason})
        end
    end
  end

  @doc """
  Check if audio is cached and get info.
  If not cached, triggers download and returns the URL when ready.

  GET /api/music/info/:video_id
  """
  def info(conn, %{"video_id" => video_id}) do
    case get_cached_url(video_id) do
      {:ok, url} ->
        json(conn, %{
          video_id: video_id,
          cached: true,
          stream_url: url
        })

      :not_cached ->
        # Trigger download and return URL when ready
        case download_and_upload(video_id) do
          {:ok, url} ->
            json(conn, %{
              video_id: video_id,
              cached: true,
              stream_url: url
            })

          {:error, reason} ->
            Logger.warning("[MusicController] Info download failed: #{reason}")
            # Fallback: get direct stream URL from yt-dlp
            case get_direct_stream_url(video_id) do
              {:ok, direct_url} ->
                json(conn, %{
                  video_id: video_id,
                  cached: false,
                  stream_url: direct_url
                })

              {:error, _} ->
                conn
                |> put_status(500)
                |> json(%{error: "Failed to get stream URL", reason: reason})
            end
        end
    end
  end

  # Get direct stream URL without downloading (for fallback)
  defp get_direct_stream_url(video_id) do
    case YtDlp.get_stream_url(video_id) do
      {:ok, %{stream_url: url}} when not is_nil(url) -> {:ok, url}
      _ -> {:error, "No stream URL available"}
    end
  end

  # Private functions

  defp get_cached_url(video_id) do
    # Check database for cached entry with Supabase URL
    case MusicCache.get_by_video_id(video_id) do
      %MusicCache{cached_file_path: url} when not is_nil(url) and url != "" ->
        # cached_file_path stores the Supabase public URL
        {:ok, SupabaseStorage.rewrite_public_url(url)}

      _ ->
        :not_cached
    end
  end

  defp download_and_upload(video_id) do
    Logger.info("[MusicController] Downloading audio for: #{video_id}")

    # Ensure temp directory exists
    File.mkdir_p!(@temp_dir)

    # Safe filename
    safe_id = String.replace(video_id, ~r/[^a-zA-Z0-9_-]/, "_")
    temp_path = Path.join(@temp_dir, "#{safe_id}.m4a")
    remote_path = "#{safe_id}.m4a"

    # Use yt-dlp to download the audio file
    # Use simplified format selector that works across all videos
    args = [
      "-f", "ba/b",  # best audio, or best overall if no audio-only
      "-x",  # Extract audio
      "--audio-format", "m4a",  # Convert to m4a
      "--no-playlist",
      "--no-warnings",
      "-o", temp_path,
      "--",
      "https://www.youtube.com/watch?v=#{video_id}"
    ]

    # Run yt-dlp with timeout
    task = Task.async(fn ->
      try do
        case System.cmd("yt-dlp", args, stderr_to_stdout: true) do
          {_output, 0} -> {:ok, temp_path}
          {output, code} ->
            Logger.warning("[MusicController] yt-dlp exit #{code}: #{String.slice(output, 0, 200)}")
            {:error, "Download failed with code #{code}"}
        end
      rescue
        e -> {:error, "Exception: #{inspect(e)}"}
      end
    end)

    # 2 minute timeout for download
    result = case Task.yield(task, 120_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, path}} ->
        # Get file size
        case File.stat(path) do
          {:ok, stat} ->
            # Upload to Supabase Storage
            case SupabaseStorage.upload(path, remote_path) do
              {:ok, public_url} ->
                # Save URL to database
                save_to_database(video_id, public_url, stat.size)
                # Clean up temp file
                File.rm(path)
                {:ok, public_url}

              {:error, reason} ->
                Logger.error("[MusicController] Supabase upload failed: #{reason}")
                # Fallback: Keep local file and serve directly for this session
                {:error, "Supabase upload failed: #{reason}"}
            end

          {:error, reason} ->
            {:error, "Could not stat file: #{inspect(reason)}"}
        end

      {:ok, {:error, reason}} ->
        {:error, reason}

      nil ->
        {:error, "Download timeout"}
    end

    # Clean up temp file if it exists
    File.rm(temp_path)

    result
  end

  defp save_to_database(video_id, url, size) do
    # Update or create database entry
    now = DateTime.utc_now()

    case MusicCache.get_by_video_id(video_id) do
      nil ->
        # Create new entry
        %MusicCache{}
        |> Ecto.Changeset.cast(%{
          video_id: video_id,
          title: video_id,
          query: video_id,
          query_hash: hash_string(video_id),
          cached_file_path: url,
          file_size_bytes: size,
          cached_at: now
        }, [:video_id, :title, :query, :query_hash, :cached_file_path, :file_size_bytes, :cached_at])
        |> Repo.insert()
        |> log_result("Created")

      entry ->
        # Update existing
        entry
        |> Ecto.Changeset.cast(%{
          cached_file_path: url,
          file_size_bytes: size,
          cached_at: now
        }, [:cached_file_path, :file_size_bytes, :cached_at])
        |> Repo.update()
        |> log_result("Updated")
    end
  end

  defp hash_string(str) do
    :crypto.hash(:sha256, str)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 32)
  end

  defp log_result({:ok, _}, action), do: Logger.info("[MusicController] #{action} cache entry")
  defp log_result({:error, changeset}, action), do: Logger.error("[MusicController] Failed to #{action}: #{inspect(changeset.errors)}")
end
