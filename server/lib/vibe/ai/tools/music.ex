defmodule Vibe.AI.Tools.Music do
  @moduledoc """
  Music search tool using yt-dlp for free, full-length audio streaming.

  Architecture:
  1. Check database cache first (avoids refetching)
  2. If not cached, use yt-dlp to search YouTube
  3. Cache results for 6 hours (stream URLs expire)
  4. Fallback to Deezer for metadata if yt-dlp fails

  This approach:
  - No API keys needed (yt-dlp is free)
  - Full audio, not 30-second previews
  - Server stays light (results are cached)
  - Non-blocking (yt-dlp runs in async Task)
  """

  require Logger

  alias Vibe.MusicCache
  alias Vibe.AI.Tools.YtDlp

  @deezer_api "https://api.deezer.com"

  @doc """
  Search for music across multiple sources.
  Returns tracks with stream URLs and metadata.
  """
  def search(%{"query" => query} = params) do
    type = params["type"] || "track"
    max_results = normalize_max_results(params["max_results"] || params[:max_results])
    Logger.info("[Music] Searching for: #{query} (type: #{type}, max_results: #{max_results})")

    # Step 1: Check cache first
    result =
      case check_cache(query) do
        {:ok, cached_tracks} when cached_tracks != [] ->
          Logger.info("[Music] Cache hit! Returning #{length(cached_tracks)} cached tracks")
          format_cached_results(cached_tracks)

        _ ->
          # Step 2: Fresh search with yt-dlp
          search_fresh(query, type)
      end

    limit_tracks(result, max_results)
  end

  # Default to a single best match; the agent opts into more only when the user
  # explicitly asks for options. Clamp to a sane 1..5 range.
  defp normalize_max_results(value) do
    n =
      cond do
        is_integer(value) -> value
        is_binary(value) -> case Integer.parse(value) do
            {i, _} -> i
            :error -> 1
          end
        true -> 1
      end

    n |> max(1) |> min(5)
  end

  # Trim the emitted track list to the requested count without losing the
  # source/primary metadata the rest of the pipeline expects.
  defp limit_tracks(%{tracks: tracks} = result, max_results) when is_list(tracks) do
    Map.put(result, :tracks, Enum.take(tracks, max_results))
  end

  defp limit_tracks(result, _max_results), do: result

  # Handle missing query parameter
  def search(params) do
    Logger.error("[Music] Called with invalid params: #{inspect(params)}")
    %{error: "Missing search query"}
  end

  # Check database cache for this query
  defp check_cache(query) do
    try do
      cached = MusicCache.get_cached(query)
      if cached != [] do
        {:ok, cached}
      else
        {:ok, []}
      end
    rescue
      e ->
        Logger.warning("[Music] Cache lookup failed: #{inspect(e)}")
        {:error, :cache_error}
    end
  end

  # Fresh search using yt-dlp - FAST mode (metadata only, no stream extraction)
  defp search_fresh(query, _type) do
    # Use fast flat-playlist search (just metadata, no stream URLs)
    # Stream URLs will be fetched on-demand when user plays
    # Return 1 primary result + up to 2 alternatives
    limit = 3

    case YtDlp.search(query, limit: limit) do
      {:ok, tracks} when tracks != [] ->
        Logger.info("[Music] yt-dlp returned #{length(tracks)} results (fast mode)")

        # Cache metadata for future requests
        spawn(fn -> cache_results(query, tracks) end)

        format_ytdlp_results(tracks)

      {:ok, []} ->
        # If exact match fails, try adding "audio" to query
        Logger.info("[Music] Initial search failed, trying with 'audio' suffix")
        retry_search(query <> " audio")

      {:error, reason} ->
        Logger.error("[Music] yt-dlp failed: #{reason}")
        %{error: "Could not find that song. Please try again."}
    end
  end

  defp retry_search(query) do
    case YtDlp.search(query, limit: 1) do
      {:ok, tracks} when tracks != [] ->
        spawn(fn -> cache_results(query, tracks) end)
        format_ytdlp_results(tracks)
      _ ->
        %{error: "No results found for music query"}
    end
  end

  # Removed Deezer fallback as per user request to avoid 30s previews

  # Cache results to database
  defp cache_results(query, tracks) do
    try do
      MusicCache.cache_results(query, tracks, "youtube")
      Logger.info("[Music] Cached #{length(tracks)} tracks for query: #{query}")
    rescue
      e -> Logger.warning("[Music] Failed to cache results: #{inspect(e)}")
    end
  end

  # Format yt-dlp results (handles both flat-playlist and full extraction)
  # Returns primary track first, then alternatives
  defp format_ytdlp_results(tracks) do
    formatted = Enum.map(tracks, fn track ->
      video_id = track[:video_id] || track[:id]

      %{
        video_id: video_id, # Critical for backend proxy to fetch stream on-demand
        title: track[:title],
        artist: track[:artist],
        album: nil,
        duration: track[:duration],
        # For flat-playlist mode, stream_url is nil - will be fetched on-demand via /api/music/stream/:id
        preview_url: track[:stream_url] || track[:preview_url],
        cover: track[:cover],
        links: track[:links] || %{
          youtube: "https://www.youtube.com/watch?v=#{video_id}",
          youtube_music: "https://music.youtube.com/watch?v=#{video_id}"
        }
      }
    end)

    # Split into primary and alternatives
    {primary, alternatives} = case formatted do
      [first | rest] -> {first, rest}
      [] -> {nil, []}
    end

    %{
      source: "youtube",
      count: length(formatted),
      primary: primary,
      alternatives: alternatives,
      tracks: formatted  # Keep full list for backwards compatibility
    }
  end

  # Format cached results
  defp format_cached_results(cached_tracks) do
    formatted = Enum.map(cached_tracks, fn track ->
      %{
        video_id: track.video_id,
        title: track.title,
        artist: track.artist,
        album: track.album,
        duration: track.duration,
        preview_url: track.stream_url || track.preview_url,
        cover: track.cover_url,
        links: track.external_links || %{}
      }
    end)

    %{
      source: "cache",
      count: length(formatted),
      tracks: formatted
    }
  end

  # Format Deezer results
  defp format_deezer_results(results) do
    tracks = Enum.map(results, fn item ->
      %{
        title: item["title"] || item["name"],
        artist: get_in(item, ["artist", "name"]) || item["name"],
        album: get_in(item, ["album", "title"]),
        duration: format_duration(item["duration"]),
        preview_url: item["preview"], # 30-second preview
        cover: get_in(item, ["album", "cover_medium"]) || item["picture_medium"],
        links: %{
          deezer: item["link"],
          spotify: build_spotify_link(item["title"], get_in(item, ["artist", "name"])),
          youtube_music: build_ytmusic_link(item["title"], get_in(item, ["artist", "name"]))
        }
      }
    end)

    %{
      source: "deezer",
      count: length(tracks),
      tracks: tracks
    }
  end

  defp format_duration(nil), do: nil
  defp format_duration(seconds) when is_integer(seconds) do
    minutes = div(seconds, 60)
    secs = rem(seconds, 60)
    "#{minutes}:#{String.pad_leading(Integer.to_string(secs), 2, "0")}"
  end

  defp build_spotify_link(title, artist) when is_binary(title) do
    query = if artist, do: "#{title} #{artist}", else: title
    "https://open.spotify.com/search/#{URI.encode(query)}"
  end
  defp build_spotify_link(_, _), do: nil

  defp build_ytmusic_link(title, artist) when is_binary(title) do
    query = if artist, do: "#{title} #{artist}", else: title
    "https://music.youtube.com/search?q=#{URI.encode(query)}"
  end
  defp build_ytmusic_link(_, _), do: nil
end
