defmodule Vibe.Chat.Room do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false} # Chat IDs are generated strings
  schema "chats" do
    field :is_group, :boolean, default: false
    field :name, :string
    field :type, :string, default: "dm"           # "dm", "group", "channel"
    field :description, :string
    field :avatar_url, :string

    belongs_to :creator, Vibe.Accounts.User, type: :binary_id
    has_many :participants, Vibe.Chat.Participant
    has_many :messages, Vibe.Chat.Message, foreign_key: :chat_id

    timestamps()
  end

  def changeset(chat, attrs) do
    chat
    |> cast(attrs, [:id, :is_group, :name, :type, :description, :avatar_url, :creator_id])
    |> validate_inclusion(:type, ["dm", "group", "channel"])
  end
end
