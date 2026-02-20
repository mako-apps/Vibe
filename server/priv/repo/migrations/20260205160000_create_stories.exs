defmodule Vibe.Repo.Migrations.CreateStories do
  use Ecto.Migration

  def change do
    create table(:stories, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)
      add :media_url, :text, null: false
      add :media_type, :string, default: "image"
      add :caption, :text
      add :duration, :integer, default: 5
      add :original_media_url, :text
      add :visibility, :string, default: "everyone"
      add :visible_to, {:array, :string}, default: []
      add :hidden_from, {:array, :string}, default: []
      add :view_count, :integer, default: 0
      add :expires_at, :utc_datetime, null: false

      timestamps()
    end

    create index(:stories, [:user_id])
    create index(:stories, [:expires_at])
    create index(:stories, [:user_id, :expires_at])

    create table(:story_views, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :story_id, references(:stories, type: :binary_id, on_delete: :delete_all)
      add :viewer_id, references(:users, type: :binary_id, on_delete: :delete_all)

      timestamps(updated_at: false)
    end

    create index(:story_views, [:story_id])
    create index(:story_views, [:viewer_id])
    create unique_index(:story_views, [:story_id, :viewer_id])
  end
end
