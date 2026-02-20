defmodule Vibe.Chat.PinnedMessage do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @derive {Jason.Encoder, only: [:id, :user_id, :chat_id, :message_id, :inserted_at]}
  schema "pinned_messages" do
    belongs_to :user, Vibe.Accounts.User, type: :binary_id
    belongs_to :chat, Vibe.Chat.Room, type: :string
    belongs_to :message, Vibe.Chat.Message, type: :binary_id

    timestamps(updated_at: false)
  end

  def changeset(pinned_message, attrs) do
    pinned_message
    |> cast(attrs, [:user_id, :chat_id, :message_id])
    |> validate_required([:user_id, :chat_id, :message_id])
    |> unique_constraint([:user_id, :chat_id, :message_id])
  end
end
