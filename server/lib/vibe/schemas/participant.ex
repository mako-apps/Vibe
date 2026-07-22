defmodule Vibe.Chat.Participant do
  use Ecto.Schema
  import Ecto.Changeset

  schema "chat_participants" do
    belongs_to(:chat, Vibe.Chat.Room, type: :string)
    belongs_to(:user, Vibe.Accounts.User, type: :binary_id)

    field(:muted, :boolean, default: false)
    field(:pinned, :boolean, default: false)
    field(:marked_unread, :boolean, default: false)
    field(:archived, :boolean, default: false)
    field(:deleted, :boolean, default: false)
    field(:messages_cleared_at, :naive_datetime)
    field(:role, :string, default: "member")

    timestamps()
  end

  def changeset(participant, attrs) do
    participant
    |> cast(attrs, [
      :chat_id,
      :user_id,
      :muted,
      :pinned,
      :marked_unread,
      :archived,
      :messages_cleared_at,
      :role
    ])
    |> validate_required([:chat_id, :user_id])
    |> validate_inclusion(:role, ["owner", "admin", "member", "subscriber", "agent_admin"])
  end
end
