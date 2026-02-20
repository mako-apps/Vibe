defmodule Vibe.Subscriptions.Plan do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "subscription_plans" do
    field :name, :string
    field :price_cents, :integer, default: 0
    field :interval, :string, default: "monthly"
    field :features, {:array, :string}, default: []
    field :lemon_squeezy_variant_id, :string
    field :referral_threshold, :integer
    field :ai_features_enabled, :boolean, default: false
    field :business_auto_reply, :boolean, default: false

    has_many :subscriptions, Vibe.Subscriptions.UserSubscription, foreign_key: :plan_id

    timestamps()
  end

  def changeset(plan, attrs) do
    plan
    |> cast(attrs, [
      :name,
      :price_cents,
      :interval,
      :features,
      :lemon_squeezy_variant_id,
      :referral_threshold,
      :ai_features_enabled,
      :business_auto_reply
    ])
    |> validate_required([:name, :price_cents])
    |> validate_inclusion(:interval, ["monthly", "yearly"])
    |> unique_constraint(:name)
  end
end
