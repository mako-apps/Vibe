defmodule Vibe.Repo.Migrations.CreateBadges do
  use Ecto.Migration

  def change do
    create table(:badges, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :badge_type, :string, null: false
      add :earned_at, :utc_datetime, null: false
      add :source, :string, null: false
      add :active, :boolean, default: true

      timestamps()
    end

    create index(:badges, [:user_id])
    create index(:badges, [:badge_type])
    create unique_index(:badges, [:user_id, :badge_type])
  end
end
