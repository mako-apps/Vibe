defmodule Vibe.Repo.Migrations.AddGroupsAndChannels do
  use Ecto.Migration

  def change do
    # Add type and metadata to chats table
    alter table(:chats) do
      add :type, :string, default: "dm"
      add :description, :text
      add :avatar_url, :text
      add :creator_id, references(:users, type: :binary_id, on_delete: :nilify_all)
    end

    # Add role to participants
    alter table(:chat_participants) do
      add :role, :string, default: "member"
    end

    create index(:chats, [:type])
    create index(:chats, [:creator_id])
  end
end
