defmodule Vibe.Repo.Migrations.CreateSubscriptionPlans do
  use Ecto.Migration

  def change do
    create table(:subscription_plans, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :string, null: false
      add :price_cents, :integer, null: false, default: 0
      add :interval, :string, default: "monthly"
      add :features, {:array, :string}, default: []
      add :lemon_squeezy_variant_id, :string
      add :referral_threshold, :integer
      add :ai_features_enabled, :boolean, default: false
      add :business_auto_reply, :boolean, default: false

      timestamps()
    end

    create unique_index(:subscription_plans, [:name])
    create index(:subscription_plans, [:lemon_squeezy_variant_id])
  end
end
