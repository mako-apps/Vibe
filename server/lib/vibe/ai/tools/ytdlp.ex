defmodule Vibe.AI.Tools.YtDlp do
  @moduledoc """
  yt-dlp wrapper for extracting audio streams from YouTube and other platforms.
  Runs as a subprocess to avoid blocking the main server.

  Features:
  - Search YouTube for music
  - Extract audio stream URLs (no download, just URL extraction)
  - Get metadata (title, artist, duration, thumbnail)
  - Non-blocking via Task.async
  """

  require Logger

  @timeout 30_000  # 30 seconds max per request (fast mode should be <5s)

  @doc """
  Search for music and get stream URL.
  Returns {:ok, track_info} or {:error, reason}
  """
  def search(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 3)

    # Use ytsearch to search YouTube
    search_query = "ytsearch#{limit}:#{query}"

    # FAST mode: --flat-playlist skips stream extraction (just metadata)
    # This is 10x faster than full extraction
    base_args = [
      "--no-download",
      "--print-json",
      "--flat-playlist",  # Critical: only get metadata, no stream URLs
      "--no-warnings",
      "--ignore-errors",
      "--extractor-retries", "2",
      "--socket-timeout", "10",
      "--user-agent", random_user_agent(),
      "--referer", "https://www.youtube.com/"
    ]

    # Add cookies if available
    args = case get_cookies_path() do
      nil -> base_args ++ [search_query]
      path -> base_args ++ ["--cookies", path, search_query]
    end

    case run_ytdlp(args) do
      {:ok, output} ->
        tracks = parse_search_results(output)
        {:ok, tracks}

      {:error, reason} ->
        Logger.error("[YtDlp] Search failed: #{reason}")
        {:error, reason}
    end
  end

  @doc """
  Get detailed info including stream URL for a specific video.
  This extracts the actual playable audio URL.
  """
  def get_stream_url(video_id_or_url) do
    url = normalize_url(video_id_or_url)

    base_args = [
      "--no-download",
      "--print-json",
      # More flexible format: try audio formats, then any best format
      "-f", "bestaudio/bestaudio*/best",
      "--no-playlist",
      "--no-warnings",
      "--extractor-retries", "3",
      "--user-agent", random_user_agent(),
      "--referer", "https://www.youtube.com/",
      "--add-header", "Accept-Language:en-US,en;q=0.9"
    ]

    args = case get_cookies_path() do
      nil -> base_args ++ [url]
      path -> base_args ++ ["--cookies", path, url]
    end

    case run_ytdlp(args) do
      {:ok, output} ->
        case Jason.decode(output) do
          {:ok, data} ->
            {:ok, %{
              video_id: data["id"],
              title: data["title"],
              artist: data["uploader"] || data["channel"],
              duration: format_duration(data["duration"]),
              duration_seconds: data["duration"],
              cover: data["thumbnail"],
              stream_url: data["url"],
              formats: extract_formats(data["formats"])
            }}

          {:error, _} ->
            {:error, "Failed to parse response"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Search and get full stream info in one call (for caching).
  Returns list of tracks with stream URLs.
  """
  def search_with_streams(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 3)

    # Direct search with full extraction
    search_query = "ytsearch#{limit}:#{query}"

    base_args = [
      "--no-download",
      "--print-json",
      # More flexible format: try audio formats, then any best format
      "-f", "bestaudio/bestaudio*/best",
      "--no-warnings",
      "--ignore-errors",
      "--extractor-retries", "3",
      "--sleep-requests", "1",
      "--user-agent", random_user_agent(),
      "--referer", "https://www.youtube.com/",
      "--add-header", "Accept-Language:en-US,en;q=0.9",
      "--add-header", "Accept:text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
    ]

    args = case get_cookies_path() do
      nil -> base_args ++ [search_query]
      path -> base_args ++ ["--cookies", path, search_query]
    end

    case run_ytdlp(args) do
      {:ok, output} ->
        tracks = parse_full_results(output)
        {:ok, tracks}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Run yt-dlp as subprocess
  defp run_ytdlp(args) do
    Logger.info("[YtDlp] Running: yt-dlp #{Enum.join(args, " ")}")

    task = Task.async(fn ->
      try do
        case System.cmd("yt-dlp", args, stderr_to_stdout: true) do
          {output, 0} ->
            {:ok, output}

          {output, code} ->
            Logger.warning("[YtDlp] Exit code #{code}: #{String.slice(output, 0, 500)}")
            # Try to extract partial results even on error
            if String.contains?(output, "\"id\":") do
              {:ok, output}
            else
              {:error, "yt-dlp exited with code #{code}"}
            end
        end
      rescue
        e ->
          Logger.error("[YtDlp] Exception: #{inspect(e)}")
          {:error, "yt-dlp not available"}
      end
    end)

    case Task.yield(task, @timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, "Timeout after #{@timeout}ms"}
    end
  end

  # Parse flat playlist search results
  defp parse_search_results(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "{"))
    |> Enum.map(fn line ->
      case Jason.decode(line) do
        {:ok, data} ->
          %{
            video_id: data["id"],
            title: data["title"],
            artist: data["uploader"] || data["channel"],
            duration: format_duration(data["duration"]),
            duration_seconds: data["duration"],
            cover: data["thumbnail"] || data["thumbnails"] |> List.first() |> then(& &1["url"]),
            url: "https://www.youtube.com/watch?v=#{data["id"]}"
          }

        _ ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  # Parse full results with stream URLs
  defp parse_full_results(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "{"))
    |> Enum.map(fn line ->
      case Jason.decode(line) do
        {:ok, data} ->
          thumbnail = case data["thumbnail"] do
            nil -> get_best_thumbnail(data["thumbnails"])
            url -> url
          end

          %{
            video_id: data["id"],
            title: data["title"],
            artist: data["uploader"] || data["channel"],
            duration: format_duration(data["duration"]),
            duration_seconds: data["duration"],
            cover: thumbnail,
            stream_url: data["url"],  # Direct audio stream URL
            preview_url: data["url"], # Same as stream for full audio
            links: %{
              youtube: "https://www.youtube.com/watch?v=#{data["id"]}",
              youtube_music: "https://music.youtube.com/watch?v=#{data["id"]}"
            }
          }

        _ ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp get_best_thumbnail(nil), do: nil
  defp get_best_thumbnail([]), do: nil
  defp get_best_thumbnail(thumbnails) do
    # Prefer medium/high quality
    Enum.find(thumbnails, fn t -> t["height"] && t["height"] >= 360 end)
    |> then(fn
      nil -> List.last(thumbnails)
      t -> t
    end)
    |> then(& &1["url"])
  end

  defp extract_formats(nil), do: []
  defp extract_formats(formats) do
    formats
    |> Enum.filter(fn f -> f["acodec"] && f["acodec"] != "none" end)
    |> Enum.map(fn f ->
      %{
        format_id: f["format_id"],
        ext: f["ext"],
        quality: f["quality"],
        abr: f["abr"],
        url: f["url"]
      }
    end)
  end

  defp normalize_url(input) when is_binary(input) do
    cond do
      String.starts_with?(input, "http") -> input
      String.length(input) == 11 -> "https://www.youtube.com/watch?v=#{input}"
      true -> input
    end
  end

  defp format_duration(nil), do: "0:00"
  defp format_duration(seconds) when is_number(seconds) do
    seconds = round(seconds)
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    secs = rem(seconds, 60)

    if hours > 0 do
      "#{hours}:#{String.pad_leading("#{minutes}", 2, "0")}:#{String.pad_leading("#{secs}", 2, "0")}"
    else
      "#{minutes}:#{String.pad_leading("#{secs}", 2, "0")}"
    end
  end
  defp format_duration(_), do: "0:00"

  # Random user agent to avoid detection
  defp random_user_agent do
    agents = [
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0",
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Safari/605.1.15",
      "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    ]
    Enum.random(agents)
  end

  # Check for cookies file (set via environment variable or default path)
  defp get_cookies_path do
    # 1. Try to generate from content env var (most reliable)
    case System.get_env("YTDLP_COOKIES_CONTENT") do
      nil -> check_existing_paths()
      content ->
        path = "/tmp/cookies.txt"
        File.write!(path, content)
        path
    end
  end

  defp check_existing_paths do
    case System.get_env("YTDLP_COOKIES_PATH") do
      nil ->
        # Check default locations
        default_path = "/app/cookies.txt"
        if File.exists?(default_path), do: default_path, else: nil
      path ->
        if File.exists?(path), do: path, else: nil
    end
  end
end
