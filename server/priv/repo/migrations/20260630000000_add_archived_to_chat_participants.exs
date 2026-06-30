defmodule Vibe.Repo.Migrations.AddArchivedToChatParticipants do
  use Ecto.Migration

  def change do
    alter table(:chat_participants) do
      add(:archived, :boolean, default: false)
    end

    create(index(:chat_participants, [:archived]))
  end
end
