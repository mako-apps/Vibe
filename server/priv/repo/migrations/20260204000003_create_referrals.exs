defmodule Vibe.Repo.Migrations.CreateReferrals do
  use Ecto.Migration

  def change do
    create table(:referrals, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :referrer_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :referred_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :referral_code, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :verified_at, :utc_datetime

      timestamps()
    end

    create index(:referrals, [:referrer_id])
    create index(:referrals, [:referral_code])
    create index(:referrals, [:status])
    create unique_index(:referrals, [:referred_id])
  end
end
