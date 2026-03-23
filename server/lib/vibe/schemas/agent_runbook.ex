defmodule Vibe.AgentRunbook do
  use Ecto.Schema
  import Ecto.Changeset

  @risk_levels ~w[low medium high]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_runbooks" do
    field :name, :string
    field :event_types_enabled, {:array, :string}, default: []
    field :risk_level, :string, default: "low"
    field :action_type, :string
    field :instructions, :string
    field :conditions, :map, default: %{}
    field :action_config, :map, default: %{}
    field :enabled, :boolean, default: true

    belongs_to :agent, Vibe.Agent
    belongs_to :integration, Vibe.AgentIntegration

    timestamps()
  end

  def changeset(runbook, attrs) do
    runbook
    |> cast(attrs, [
      :agent_id,
      :integration_id,
      :name,
      :event_types_enabled,
      :risk_level,
      :action_type,
      :instructions,
      :conditions,
      :action_config,
      :enabled
    ])
    |> validate_required([:agent_id, :name, :action_type])
    |> validate_length(:name, min: 1, max: 120)
    |> validate_inclusion(:risk_level, @risk_levels)
  end
end
