defmodule Vibe.Subscriptions.UserSubscription do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "user_subscriptions" do
    field :status, :string, default: "active"
    field :lemon_squeezy_subscription_id, :string
    field :lemon_squeezy_customer_id, :string
    field :current_period_start, :utc_datetime
    field :current_period_end, :utc_datetime
    field :cancelled_at, :utc_datetime

    belongs_to :user, Vibe.Accounts.User
    belongs_to :plan, Vibe.Subscriptions.Plan

    timestamps()
  end

  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [
      :user_id,
      :plan_id,
      :status,
      :lemon_squeezy_subscription_id,
      :lemon_squeezy_customer_id,
      :current_period_start,
      :current_period_end,
      :cancelled_at
    ])
    |> validate_required([:user_id, :plan_id, :status])
    |> validate_inclusion(:status, ["active", "cancelled", "past_due", "trialing"])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:plan_id)
    |> unique_constraint(:lemon_squeezy_subscription_id)
  end
end
