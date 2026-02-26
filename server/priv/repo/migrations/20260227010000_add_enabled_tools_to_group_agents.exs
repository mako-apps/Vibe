defmodule Vibe.Repo.Migrations.AddEnabledToolsToGroupAgents do
  use Ecto.Migration

  def change do
    alter table(:group_agents) do
      add :enabled_tools, {:array, :string},
        default: ["search_google", "analyze_image", "analyze_document", "create_document"],
        null: false
    end
  end
end
