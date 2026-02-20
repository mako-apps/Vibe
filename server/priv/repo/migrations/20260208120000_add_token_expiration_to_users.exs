defmodule Vibe.Repo.Migrations.AddTokenExpirationToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # SECURITY: Add token expiration column
      # Tokens will now expire after a configurable period (default 30 days)
      add :token_expires_at, :utc_datetime, null: true
    end

    # Create index for efficient token expiration queries
    create index(:users, [:token_expires_at])
  end
end
