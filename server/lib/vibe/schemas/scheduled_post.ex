defmodule Vibe.Chat.ScheduledPost do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "scheduled_posts" do
    field :content, :string
    field :type, :string, default: "text"
    field :media_url, :string
    field :scheduled_at, :utc_datetime
    field :status, :string, default: "pending"
    field :posted_at, :utc_datetime

    belongs_to :channel, Vibe.Chat.Room, type: :string, foreign_key: :channel_id
    belongs_to :user, Vibe.Accounts.User, type: :binary_id

    timestamps()
  end

  def changeset(post, attrs) do
    post
    |> cast(attrs, [:content, :type, :media_url, :scheduled_at, :status, :posted_at, :channel_id, :user_id])
    |> validate_required([:content, :channel_id, :user_id, :scheduled_at])
    |> validate_inclusion(:status, ["pending", "posted", "cancelled"])
    |> validate_inclusion(:type, ["text", "image", "media"])
  end
end
