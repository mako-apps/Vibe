defmodule Vibe.AgentEventThread do
  use Ecto.Schema
  import Ecto.Changeset

  @priorities ~w[low normal high urgent]
  @statuses ~w[open in_progress blocked resolved archived]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_event_threads" do
    field :chat_id, :string
    field :source, :string
    field :thread_key, :string
    field :title, :string
    field :summary, :string
    field :current_state, :map, default: %{}
    field :priority, :string, default: "normal"
    field :status, :string, default: "open"
    field :last_decision, :string
    field :latest_event_at, :utc_datetime

    belongs_to :agent, Vibe.Agent
    belongs_to :integration, Vibe.AgentIntegration
    belongs_to :root_message, Vibe.Chat.Message, type: :binary_id
    has_many :events, Vibe.AgentEvent, foreign_key: :thread_id
    has_many :approval_tasks, Vibe.AgentApprovalTask, foreign_key: :thread_id
    has_many :runs, Vibe.AgentRun, foreign_key: :thread_id

    timestamps()
  end

  def changeset(thread, attrs) do
    thread
    |> cast(attrs, [
      :agent_id,
      :integration_id,
      :chat_id,
      :source,
      :thread_key,
      :title,
      :summary,
      :current_state,
      :priority,
      :status,
      :last_decision,
      :latest_event_at,
      :root_message_id
    ])
    |> validate_required([:agent_id, :source, :thread_key, :chat_id])
    |> validate_inclusion(:priority, @priorities)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:agent_id, :source, :thread_key],
      name: :agent_event_threads_agent_id_source_thread_key_index
    )
  end
end
