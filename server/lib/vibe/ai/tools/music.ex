defmodule Vibe.AI.Tools.Music do
  @moduledoc """
  Music search + URL resolve tool using yt-dlp for free, full-length audio streaming.

  Architecture:
  1. If the query is a music page URL (SoundCloud, YouTube, …), resolve it with yt-dlp
  2. Else check database cache, then YouTube search via yt-dlp
  3. Cache results (stream URLs expire; playback uses `/api/music/stream/:id`)
  4. Agent turn pipeline turns tracks into playable `music` rich messages

  Supported URL hosts include SoundCloud and YouTube (and other yt-dlp extractors).
  """

  require Logger

  alias Vibe.MusicCache
  alias Vibe.AI.Tools.YtDlp

  @doc """
  Search for music or resolve a share URL into playable track(s).

  Params:
  - `query` (required for search) — song/artist text **or** a SoundCloud/YouTube URL
  - `url` (optional) — explicit page URL; takes precedence over query when present
  - `type` — track | album | artist (search only)
  - `max_results` — 1..5 (default 1)
  """
  def search(params) when is_map(params) do
    url = extract_url(params)
    query = extract_query(params)
    max_results = normalize_max_results(params["max_results"] || params[:max_results])
    type = params["type"] || "track"

    cond do
      is_binary(url) ->
        Logger.info("[Music] Resolving URL: #{url}")
        resolve_page_url(url)

      is_binary(query) and YtDlp.music_page_url?(query) ->
        Logger.info("[Music] Resolving music page from query: #{query}")
        resolve_page_url(String.trim(query))

      is_binary(query) ->
        Logger.info("[Music] Searching for: #{query} (type: #{type}, max_results: #{max_results})")

        result =
          case check_cache(query) do
            {:ok, cached_tracks} when cached_tracks != [] ->
              Logger.info("[Music] Cache hit! Returning #{length(cached_tracks)} cached tracks")
              format_cached_results(cached_tracks)

            _ ->
              search_fresh(query, type)
          end

        limit_tracks(result, max_results)

      true ->
        Logger.error("[Music] Called with invalid params: #{inspect(params)}")
        %{error: "Missing search query or url"}
    end
  end

  def search(params) do
    Logger.error("[Music] Called with invalid params: #{inspect(params)}")
    %{error: "Missing search query"}
  end

  # ── URL resolve (SoundCloud / YouTube / …) ──────────────────────────────

  defp resolve_page_url(url) do
    case YtDlp.resolve_url(url) do
      {:ok, track} ->
        Logger.info(
          "[Music] Resolved #{track[:source]} track=#{track[:video_id]} title=#{inspect(track[:title])}"
        )

        spawn(fn -> cache_results(url, [track], track[:source] || "web") end)
        format_resolved_track(track)

      {:error, reason} ->
        Logger.error("[Music] URL resolve failed: #{inspect(reason)}")

        %{
          error:
            "Could not load audio from that link. Supported: SoundCloud, YouTube, and other yt-dlp music pages."
        }
    end
  end

  defp format_resolved_track(track) when is_map(track) do
    formatted = %{
      video_id: track[:video_id] || track[:id],
      title: track[:title],
      artist: track[:artist],
      album: track[:album],
      duration: track[:duration],
      duration_seconds: track[:duration_seconds],
      preview_url: track[:stream_url] || track[:preview_url],
      cover: track[:cover],
      links: track[:links] || %{}
    }

    source = track[:source] || "web"

    %{
      source: source,
      count: 1,
      primary: formatted,
      alternatives: [],
      tracks: [formatted]
    }
  end

  # Default to a single best match; the agent opts into more only when the user
  # explicitly asks for options. Clamp to a sane 1..5 range.
  defp normalize_max_results(value) do
    n =
      cond do
        is_integer(value) ->
          value

        is_binary(value) ->
          case Integer.parse(value) do
            {i, _} -> i
            :error -> 1
          end

        true ->
          1
      end

    n |> max(1) |> min(5)
  end

  # Trim the emitted track list to the requested count without losing the
  # source/primary metadata the rest of the pipeline expects.
  defp limit_tracks(%{tracks: tracks} = result, max_results) when is_list(tracks) do
    Map.put(result, :tracks, Enum.take(tracks, max_results))
  end

  defp limit_tracks(result, _max_results), do: result

  defp extract_url(params) do
    raw = params["url"] || params[:url] || params["link"] || params[:link]

    case normalize_string(raw) do
      nil -> nil
      value -> if YtDlp.music_page_url?(value) or String.starts_with?(value, "http"), do: value
    end
  end

  defp extract_query(params) do
    normalize_string(params["query"] || params[:query])
  end

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_), do: nil

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
        spawn(fn -> cache_results(query, tracks, "youtube") end)

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
        spawn(fn -> cache_results(query, tracks, "youtube") end)
        format_ytdlp_results(tracks)

      _ ->
        %{error: "No results found for music query"}
    end
  end

  # Cache results to database
  defp cache_results(query, tracks, source) do
    try do
      MusicCache.cache_results(query, tracks, source || "youtube")
      Logger.info("[Music] Cached #{length(tracks)} tracks for query: #{query}")
    rescue
      e -> Logger.warning("[Music] Failed to cache results: #{inspect(e)}")
    end
  end

  # Format yt-dlp results (handles both flat-playlist and full extraction)
  # Returns primary track first, then alternatives
  defp format_ytdlp_results(tracks) do
    formatted =
      Enum.map(tracks, fn track ->
        video_id = track[:video_id] || track[:id]
        source = track[:source] || "youtube"

        links =
          track[:links] ||
            %{
              "webpage_url" => track[:webpage_url] || track[:url] ||
                "https://www.youtube.com/watch?v=#{video_id}",
              "youtube" => "https://www.youtube.com/watch?v=#{video_id}",
              "youtube_music" => "https://music.youtube.com/watch?v=#{video_id}"
            }

        %{
          # Critical for backend proxy to fetch stream on-demand
          video_id: video_id,
          title: track[:title],
          artist: track[:artist],
          album: nil,
          duration: track[:duration],
          # For flat-playlist mode, stream_url is nil — fetched via /api/music/stream/:id
          preview_url: track[:stream_url] || track[:preview_url],
          cover: track[:cover],
          links: links,
          source: source
        }
      end)

    # Split into primary and alternatives
    {primary, alternatives} =
      case formatted do
        [first | rest] -> {first, rest}
        [] -> {nil, []}
      end

    %{
      source: "youtube",
      count: length(formatted),
      primary: primary,
      alternatives: alternatives,
      # Keep full list for backwards compatibility
      tracks: formatted
    }
  end

  # Format cached results
  defp format_cached_results(cached_tracks) do
    formatted =
      Enum.map(cached_tracks, fn track ->
        %{
          video_id: track.video_id,
          title: track.title,
          artist: track.artist,
          album: track.album,
          duration: track.duration,
          preview_url: track.stream_url || track.preview_url,
          cover: track.cover_url,
          links: track.external_links || %{},
          source: track.source
        }
      end)

    %{
      source: "cache",
      count: length(formatted),
      tracks: formatted
    }
  end
end
