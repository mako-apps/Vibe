defmodule Vibe.Repo.Migrations.CreateSavedMessages do
  use Ecto.Migration

  def change do
    create table(:saved_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, on_delete: :delete_all, type: :binary_id)
      add :original_message_id, :string
      add :chat_id, :string
      add :from_id, :string
      add :encrypted_content, :text
      add :content, :text
      add :type, :string
      add :media_url, :text
      add :timestamp, :bigint
      add :extra, :text

      timestamps()
    end

    create index(:saved_messages, [:user_id])
    create unique_index(:saved_messages, [:user_id, :original_message_id])
  end
end
