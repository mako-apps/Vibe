defmodule Vibe.Repo.Migrations.AddSubscriptionFieldsToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :tier, :string, default: "free"
      add :referral_code, :string
      add :referral_count, :integer, default: 0
      add :business_profile_enabled, :boolean, default: false
      add :auto_reply_enabled, :boolean, default: false
      add :auto_reply_message, :text
      add :business_hours_start, :time
      add :business_hours_end, :time
    end

    create unique_index(:users, [:referral_code])
    create index(:users, [:tier])
  end
end
