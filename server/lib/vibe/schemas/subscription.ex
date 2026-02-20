defmodule Vibe.Accounts.Subscription do
  use Ecto.Schema
  import Ecto.Changeset

  schema "subscriptions" do
    field :endpoint, :string
    field :keys_p256dh, :string
    field :keys_auth, :string
    
    belongs_to :user, Vibe.Accounts.User, type: :binary_id

    timestamps()
  end

  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:endpoint, :keys_p256dh, :keys_auth, :user_id])
    |> validate_required([:endpoint, :user_id])
    |> unique_constraint(:endpoint)
  end
end
