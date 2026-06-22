defmodule Vibe.Repo.Migrations.AddPromptVariablesToAgents do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :prompt_variables, {:array, :map}, default: [], null: false
    end
  end
end
