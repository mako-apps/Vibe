defmodule Vibe.Repo.Migrations.CreateMusicCache do
  use Ecto.Migration

  def change do
    create table(:music_cache, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :query, :string, null: false
      add :query_hash, :string, null: false  # For faster lookups
      add :source, :string, default: "youtube"  # youtube, soundcloud, etc.
      add :video_id, :string  # YouTube video ID or equivalent
      add :title, :string
      add :artist, :string
      add :album, :string
      add :duration, :string
      add :duration_seconds, :integer
      add :cover_url, :text
      add :stream_url, :text  # Cached audio stream URL
      add :stream_expires_at, :utc_datetime  # When stream URL expires
      add :preview_url, :text  # 30-sec preview if available
      add :external_links, :map, default: %{}  # {youtube, spotify, apple_music, etc}
      add :metadata, :map, default: %{}  # Any extra data

      timestamps()
    end

    create unique_index(:music_cache, [:query_hash])
    create index(:music_cache, [:video_id])
    create index(:music_cache, [:title, :artist])
    create index(:music_cache, [:inserted_at])
  end
end
