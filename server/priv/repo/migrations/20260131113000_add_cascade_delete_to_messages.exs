defmodule Vibe.Repo.Migrations.AddCascadeDeleteToMessages do
  use Ecto.Migration

  def up do
    # Drop the existing constraint that prevents deletion
    execute "ALTER TABLE messages DROP CONSTRAINT IF EXISTS messages_from_id_fkey"

    # Add the new constraint with ON DELETE CASCADE
    execute "ALTER TABLE messages ADD CONSTRAINT messages_from_id_fkey FOREIGN KEY (from_id) REFERENCES users(id) ON DELETE CASCADE"
  end

  def down do
    execute "ALTER TABLE messages DROP CONSTRAINT IF EXISTS messages_from_id_fkey"
    execute "ALTER TABLE messages ADD CONSTRAINT messages_from_id_fkey FOREIGN KEY (from_id) REFERENCES users(id) ON DELETE NOTHING"
  end
end
