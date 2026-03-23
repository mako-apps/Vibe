defmodule Vibe.AgentIntegration do
  use Ecto.Schema
  import Ecto.Changeset

  @autonomy_modes ~w[draft_first safe_auto full_auto]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_integrations" do
    field :name, :string
    field :source_type, :string
    field :default_destination_chat_id, :string
    field :autonomy_mode, :string, default: "safe_auto"
    field :event_types_enabled, {:array, :string}, default: []
    field :routing_rules, :map, default: %{}
    field :approval_rules, :map, default: %{}
    field :cost_budget_daily, :integer
    field :cost_budget_monthly, :integer
    field :enabled, :boolean, default: true
    field :secret_hash, :string
    field :secret_encrypted, :string
    field :secret_hint, :string
    field :last_event_at, :utc_datetime

    belongs_to :agent, Vibe.Agent
    has_many :threads, Vibe.AgentEventThread, foreign_key: :integration_id
    has_many :events, Vibe.AgentEvent, foreign_key: :integration_id
    has_many :runbooks, Vibe.AgentRunbook, foreign_key: :integration_id

    timestamps()
  end

  def changeset(integration, attrs) do
    integration
    |> cast(attrs, [
      :agent_id,
      :name,
      :source_type,
      :default_destination_chat_id,
      :autonomy_mode,
      :event_types_enabled,
      :routing_rules,
      :approval_rules,
      :cost_budget_daily,
      :cost_budget_monthly,
      :enabled,
      :secret_hash,
      :secret_encrypted,
      :secret_hint,
      :last_event_at
    ])
    |> validate_required([:agent_id, :name, :source_type, :secret_hash, :secret_hint])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_inclusion(:autonomy_mode, @autonomy_modes)
    |> unique_constraint([:agent_id, :name], name: :agent_integrations_agent_id_name_index)
  end
end
