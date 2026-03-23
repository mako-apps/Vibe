defmodule Vibe.AgentRun do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w[pending completed failed]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_runs" do
    field :trigger, :string
    field :mode, :string
    field :model, :string
    field :prompt_version, :string
    field :decision, :string
    field :audit_summary, :string
    field :tool_calls, :map, default: %{"items" => []}
    field :result, :map, default: %{}
    field :status, :string, default: "completed"
    field :error, :string
    field :cost_usd, :decimal
    field :prompt_tokens, :integer
    field :completion_tokens, :integer

    belongs_to :agent, Vibe.Agent
    belongs_to :integration, Vibe.AgentIntegration
    belongs_to :thread, Vibe.AgentEventThread
    belongs_to :event, Vibe.AgentEvent
    belongs_to :runbook, Vibe.AgentRunbook

    timestamps()
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :agent_id,
      :integration_id,
      :thread_id,
      :event_id,
      :runbook_id,
      :trigger,
      :mode,
      :model,
      :prompt_version,
      :decision,
      :audit_summary,
      :tool_calls,
      :result,
      :status,
      :error,
      :cost_usd,
      :prompt_tokens,
      :completion_tokens
    ])
    |> validate_required([:agent_id, :thread_id, :event_id, :trigger, :mode, :status])
    |> validate_inclusion(:status, @statuses)
  end
end
