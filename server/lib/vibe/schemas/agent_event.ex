defmodule Vibe.AgentEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w[received logged summarized acted approval_required duplicate rejected]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_events" do
    field :event_id, :string
    field :event_type, :string
    field :source, :string
    field :title, :string
    field :text, :string
    field :attachments, :map, default: %{"items" => []}
    field :payload, :map, default: %{}
    field :occurred_at, :utc_datetime
    field :status, :string, default: "received"
    field :decision, :string
    field :decision_reason, :string

    belongs_to :agent, Vibe.Agent
    belongs_to :integration, Vibe.AgentIntegration
    belongs_to :thread, Vibe.AgentEventThread
    belongs_to :message, Vibe.Chat.Message, type: :binary_id

    timestamps()
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :agent_id,
      :integration_id,
      :thread_id,
      :message_id,
      :event_id,
      :event_type,
      :source,
      :title,
      :text,
      :attachments,
      :payload,
      :occurred_at,
      :status,
      :decision,
      :decision_reason
    ])
    |> validate_required([:agent_id, :thread_id, :source, :event_type, :payload, :status])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:agent_id, :source, :event_id],
      name: :agent_events_agent_id_source_event_id_index
    )
  end
end
