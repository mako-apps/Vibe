defmodule Vibe.Repo.Migrations.AddVideoIdIndexToMusicCache do
  use Ecto.Migration

  def change do
    # Drop the old query_hash unique index (we'll keep it as a regular index)
    drop_if_exists unique_index(:music_cache, [:query_hash])

    # Add unique constraint on video_id (the actual song identifier)
    create_if_not_exists unique_index(:music_cache, [:video_id])

    # Keep query_hash as a regular index for reference lookups
    create_if_not_exists index(:music_cache, [:query_hash])
  end
end
