defmodule Vibe.Repo.Migrations.AddClearedAtToParticipants do
  use Ecto.Migration

  def change do
    alter table(:chat_participants) do
      add :messages_cleared_at, :naive_datetime
    end
  end
end
