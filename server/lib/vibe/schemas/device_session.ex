defmodule Vibe.Schemas.DeviceSession do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "device_sessions" do
    field :user_id, :binary_id
    field :account_device_id, :binary_id
    field :token_hash, :binary
    field :expires_at, :utc_datetime
    field :last_used_at, :utc_datetime
    field :revoked_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(device_session, attrs) do
    device_session
    |> cast(attrs, [
      :user_id,
      :account_device_id,
      :token_hash,
      :expires_at,
      :last_used_at,
      :revoked_at
    ])
    |> validate_required([:user_id, :account_device_id, :token_hash, :expires_at])
    |> unique_constraint(:token_hash)
  end
end
