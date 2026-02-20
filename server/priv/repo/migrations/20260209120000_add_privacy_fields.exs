defmodule Vibe.Repo.Migrations.AddPrivacyFields do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :show_last_seen, :boolean, default: true, null: false
      add :show_online_status, :boolean, default: true, null: false
    end
  end
end
