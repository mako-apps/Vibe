defmodule Vibe.Repo.Migrations.CreatePinnedMessages do
  use Ecto.Migration

  def change do
    create table(:pinned_messages, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :chat_id, references(:chats, type: :string, on_delete: :delete_all), null: false
      add :message_id, references(:messages, type: :uuid, on_delete: :delete_all), null: false

      timestamps(updated_at: false)
    end

    create unique_index(:pinned_messages, [:user_id, :chat_id, :message_id])
    create index(:pinned_messages, [:user_id, :chat_id])
    create index(:pinned_messages, [:chat_id, :inserted_at])
  end
end
