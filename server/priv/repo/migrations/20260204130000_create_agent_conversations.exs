defmodule Vibe.Repo.Migrations.CreateAgentConversations do
  use Ecto.Migration

  def change do
    create table(:agent_conversations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :title, :string, default: "New Chat"
      add :messages, :jsonb, default: "[]"
      add :metadata, :jsonb, default: "{}"

      timestamps()
    end

    create index(:agent_conversations, [:user_id])
    create index(:agent_conversations, [:user_id, :updated_at])
  end
end
