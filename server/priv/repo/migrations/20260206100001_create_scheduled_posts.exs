defmodule Vibe.Repo.Migrations.CreateScheduledPosts do
  use Ecto.Migration

  def change do
    create table(:scheduled_posts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :channel_id, references(:chats, type: :string, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :content, :text, null: false
      add :type, :string, default: "text"
      add :media_url, :text
      add :scheduled_at, :utc_datetime, null: false
      add :status, :string, default: "pending"
      add :posted_at, :utc_datetime

      timestamps()
    end

    create index(:scheduled_posts, [:channel_id])
    create index(:scheduled_posts, [:user_id])
    create index(:scheduled_posts, [:status, :scheduled_at])
  end
end
