defmodule Vibe.Repo.Migrations.AddCachedFilePathToMusicCache do
  use Ecto.Migration

  def change do
    alter table(:music_cache) do
      add :cached_file_path, :string  # Local file path for cached audio
      add :file_size_bytes, :integer  # File size for Content-Length header
      add :cached_at, :utc_datetime   # When the file was cached
    end
  end
end
