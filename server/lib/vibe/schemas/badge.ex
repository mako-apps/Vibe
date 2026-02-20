defmodule Vibe.Badges.Badge do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "badges" do
    field :badge_type, :string
    field :earned_at, :utc_datetime
    field :source, :string
    field :active, :boolean, default: true

    belongs_to :user, Vibe.Accounts.User

    timestamps()
  end

  def changeset(badge, attrs) do
    badge
    |> cast(attrs, [:user_id, :badge_type, :earned_at, :source, :active])
    |> validate_required([:user_id, :badge_type, :earned_at, :source])
    |> validate_inclusion(:badge_type, ["bronze", "silver", "gold", "admin", "verified"])
    |> validate_inclusion(:source, ["referral", "subscription", "admin", "system"])
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:user_id, :badge_type])
  end
end
