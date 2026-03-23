defmodule Vibe.AgentApprovalTask do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w[pending approved rejected expired]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_approval_tasks" do
    field :chat_id, :string
    field :requested_action, :map, default: %{}
    field :rationale, :string
    field :status, :string, default: "pending"
    field :decision_note, :string
    field :decided_at, :utc_datetime

    belongs_to :agent, Vibe.Agent
    belongs_to :thread, Vibe.AgentEventThread
    belongs_to :event, Vibe.AgentEvent
    belongs_to :runbook, Vibe.AgentRunbook
    belongs_to :approved_by, Vibe.Accounts.User, foreign_key: :approved_by_user_id

    timestamps()
  end

  def changeset(task, attrs) do
    task
    |> cast(attrs, [
      :agent_id,
      :thread_id,
      :event_id,
      :runbook_id,
      :approved_by_user_id,
      :chat_id,
      :requested_action,
      :rationale,
      :status,
      :decision_note,
      :decided_at
    ])
    |> validate_required([:agent_id, :thread_id, :event_id, :requested_action, :status, :chat_id])
    |> validate_inclusion(:status, @statuses)
  end
end
