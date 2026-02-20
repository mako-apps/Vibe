defmodule Vibe.Chat.Message do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @derive {Jason.Encoder, only: [:id, :chat_id, :from_id, :timestamp, :type, :encrypted_content, :status, :media_url, :reply_to_id]}
  schema "messages" do
    field :encrypted_content, :string
    field :type, :string, default: "text"
    field :media_url, :string
    field :status, :string, default: "sent"
    field :timestamp, :integer # Node uses ms timestamp

    belongs_to :chat, Vibe.Chat.Room, type: :string # Chat IDs are strings in Node app
    belongs_to :from, Vibe.Accounts.User, type: :binary_id
    belongs_to :reply_to, Vibe.Chat.Message, type: :binary_id

    has_many :reads, Vibe.Chat.MessageRead

    timestamps()
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:id, :encrypted_content, :type, :media_url, :status, :timestamp, :chat_id, :from_id, :reply_to_id])
    |> validate_required([:encrypted_content, :chat_id, :from_id])
  end
end
