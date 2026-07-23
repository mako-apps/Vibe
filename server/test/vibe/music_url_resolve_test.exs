defmodule Vibe.MusicUrlResolveTest do
  use ExUnit.Case, async: true

  alias Vibe.AI.Tools.Music
  alias Vibe.AI.Tools.YtDlp

  test "music_page_url? detects SoundCloud and YouTube" do
    assert YtDlp.music_page_url?("https://soundcloud.com/artist/track-name")
    assert YtDlp.music_page_url?("https://on.soundcloud.com/abc123")
    assert YtDlp.music_page_url?("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    assert YtDlp.music_page_url?("https://youtu.be/dQw4w9WgXcQ")
    refute YtDlp.music_page_url?("taylor swift blank space")
    refute YtDlp.music_page_url?("not a url")
  end

  test "download_url_for_track_id prefers webpage_url for SoundCloud" do
    url =
      YtDlp.download_url_for_track_id("sc_12345",
        links: %{"webpage_url" => "https://soundcloud.com/a/b", "soundcloud" => "https://soundcloud.com/a/b"},
        source: "soundcloud"
      )

    assert url == "https://soundcloud.com/a/b"
  end

  test "download_url_for_track_id defaults YouTube watch URL" do
    assert YtDlp.download_url_for_track_id("dQw4w9WgXcQ") ==
             "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
  end

  test "search rejects empty params" do
    assert %{error: _} = Music.search(%{})
  end
end
