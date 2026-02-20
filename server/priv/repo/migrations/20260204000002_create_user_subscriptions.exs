defmodule Vibe.Repo.Migrations.CreateUserSubscriptions do
  use Ecto.Migration

  def change do
    create table(:user_subscriptions, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :plan_id, references(:subscription_plans, type: :binary_id, on_delete: :restrict), null: false
      add :status, :string, null: false, default: "active"
      add :lemon_squeezy_subscription_id, :string
      add :lemon_squeezy_customer_id, :string
      add :current_period_start, :utc_datetime
      add :current_period_end, :utc_datetime
      add :cancelled_at, :utc_datetime

      timestamps()
    end

    create index(:user_subscriptions, [:user_id])
    create index(:user_subscriptions, [:plan_id])
    create index(:user_subscriptions, [:status])
    create unique_index(:user_subscriptions, [:lemon_squeezy_subscription_id])
  end
end
