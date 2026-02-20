defmodule Vibe.Repo.Migrations.AddDeletedToParticipants do
  use Ecto.Migration

  def change do
    alter table(:chat_participants) do
      add :deleted, :boolean, default: false
    end

    create index(:chat_participants, [:deleted])
  end
end
