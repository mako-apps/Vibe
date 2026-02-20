defmodule Vibe.Chat.MessageRead do
  use Ecto.Schema
  import Ecto.Changeset

  schema "message_reads" do
    belongs_to :message, Vibe.Chat.Message, type: :binary_id
    belongs_to :reader, Vibe.Accounts.User, type: :binary_id
    
    timestamps()
  end

  def changeset(read, attrs) do
    read
    |> cast(attrs, [:message_id, :reader_id])
    |> validate_required([:message_id, :reader_id])
    |> unique_constraint([:message_id, :reader_id])
  end
end
