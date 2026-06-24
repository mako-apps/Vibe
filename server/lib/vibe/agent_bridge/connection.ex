defmodule Vibe.AgentBridge.Connection do
  @moduledoc """
  A paired computer (bridge daemon) belonging to a user. The bridge token is never
  stored in plaintext — only its SHA-256 hash. Revoking sets `revoked_at`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "agent_bridge_connections" do
    field :user_id, :binary_id
    field :token_hash, :string
    field :device_label, :string
    field :last_seen_at, :utc_datetime
    field :revoked_at, :utc_datetime

    timestamps()
  end

  def changeset(connection, attrs) do
    connection
    |> cast(attrs, [:user_id, :token_hash, :device_label, :last_seen_at, :revoked_at])
    |> validate_required([:user_id, :token_hash])
    |> unique_constraint(:token_hash)
  end
end
