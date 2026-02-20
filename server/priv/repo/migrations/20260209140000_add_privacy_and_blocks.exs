defmodule Vibe.Repo.Migrations.AddPrivacyAndBlocks do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :bio, :string
      add :auto_delete_timer, :integer # in minutes, 0 or null means off
      add :privacy_forward, :string, default: "everybody" # everybody, contacts, nobody
      add :privacy_calls, :string, default: "everybody"
    end

    create table(:user_blocks) do
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all)
      add :blocked_user_id, references(:users, type: :uuid, on_delete: :delete_all)
      timestamps()
    end

    create unique_index(:user_blocks, [:user_id, :blocked_user_id])
  end
end
