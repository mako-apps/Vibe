defmodule Vibe.Referrals.Referral do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "referrals" do
    field :referral_code, :string
    field :status, :string, default: "pending"
    field :verified_at, :utc_datetime

    belongs_to :referrer, Vibe.Accounts.User
    belongs_to :referred, Vibe.Accounts.User

    timestamps()
  end

  def changeset(referral, attrs) do
    referral
    |> cast(attrs, [:referrer_id, :referred_id, :referral_code, :status, :verified_at])
    |> validate_required([:referrer_id, :referred_id, :referral_code])
    |> validate_inclusion(:status, ["pending", "verified", "rewarded"])
    |> foreign_key_constraint(:referrer_id)
    |> foreign_key_constraint(:referred_id)
    |> unique_constraint(:referred_id)
  end
end
