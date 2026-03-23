defmodule Vibe.Repo.Migrations.AddAgentEventThreadsRuntime do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :autonomy_mode, :string, default: "safe_auto", null: false
      add :default_destination_chat_id, :string
      add :event_types_enabled, {:array, :string}, default: [], null: false
      add :cost_budget_daily, :integer
      add :cost_budget_monthly, :integer
      add :approval_rules, :map, default: %{}, null: false
      add :runbook_ids, {:array, :binary_id}, default: [], null: false
    end

    create index(:agents, [:default_destination_chat_id])
    create index(:agents, [:autonomy_mode])

    create table(:agent_integrations, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :source_type, :string, null: false
      add :default_destination_chat_id, :string
      add :autonomy_mode, :string, default: "safe_auto", null: false
      add :event_types_enabled, {:array, :string}, default: [], null: false
      add :routing_rules, :map, default: %{}, null: false
      add :approval_rules, :map, default: %{}, null: false
      add :cost_budget_daily, :integer
      add :cost_budget_monthly, :integer
      add :enabled, :boolean, default: true, null: false
      add :secret_hash, :string, null: false
      add :secret_encrypted, :text
      add :secret_hint, :string, null: false
      add :last_event_at, :utc_datetime

      timestamps()
    end

    create unique_index(:agent_integrations, [:agent_id, :name])
    create index(:agent_integrations, [:agent_id, :source_type])
    create index(:agent_integrations, [:enabled, :inserted_at])

    create table(:agent_event_threads, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :integration_id, references(:agent_integrations, type: :binary_id, on_delete: :nilify_all)
      add :chat_id, :string, null: false
      add :source, :string, null: false
      add :thread_key, :string, null: false
      add :title, :string
      add :summary, :text
      add :current_state, :map, default: %{}, null: false
      add :priority, :string, default: "normal", null: false
      add :status, :string, default: "open", null: false
      add :last_decision, :string
      add :latest_event_at, :utc_datetime
      add :root_message_id, references(:messages, type: :binary_id, on_delete: :nilify_all)

      timestamps()
    end

    create unique_index(:agent_event_threads, [:agent_id, :source, :thread_key],
             name: :agent_event_threads_agent_id_source_thread_key_index
           )

    create index(:agent_event_threads, [:agent_id, :chat_id, :latest_event_at])
    create index(:agent_event_threads, [:status, :priority, :latest_event_at])

    create table(:agent_events, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :integration_id, references(:agent_integrations, type: :binary_id, on_delete: :nilify_all)
      add :thread_id, references(:agent_event_threads, type: :binary_id, on_delete: :delete_all), null: false
      add :message_id, references(:messages, type: :binary_id, on_delete: :nilify_all)
      add :event_id, :string
      add :event_type, :string, null: false
      add :source, :string, null: false
      add :title, :string
      add :text, :text
      add :attachments, :map, default: %{"items" => []}, null: false
      add :payload, :map, default: %{}, null: false
      add :occurred_at, :utc_datetime
      add :status, :string, default: "received", null: false
      add :decision, :string
      add :decision_reason, :text

      timestamps()
    end

    create unique_index(:agent_events, [:agent_id, :source, :event_id],
             where: "event_id IS NOT NULL",
             name: :agent_events_agent_id_source_event_id_index
           )

    create index(:agent_events, [:thread_id, :occurred_at])
    create index(:agent_events, [:status, :inserted_at])

    create table(:agent_runbooks, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :integration_id, references(:agent_integrations, type: :binary_id, on_delete: :delete_all)
      add :name, :string, null: false
      add :event_types_enabled, {:array, :string}, default: [], null: false
      add :risk_level, :string, default: "low", null: false
      add :action_type, :string, null: false
      add :instructions, :text
      add :conditions, :map, default: %{}, null: false
      add :action_config, :map, default: %{}, null: false
      add :enabled, :boolean, default: true, null: false

      timestamps()
    end

    create index(:agent_runbooks, [:agent_id, :integration_id])
    create index(:agent_runbooks, [:enabled, :inserted_at])

    create table(:agent_approval_tasks, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :thread_id, references(:agent_event_threads, type: :binary_id, on_delete: :delete_all), null: false
      add :event_id, references(:agent_events, type: :binary_id, on_delete: :delete_all), null: false
      add :runbook_id, references(:agent_runbooks, type: :binary_id, on_delete: :nilify_all)
      add :approved_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :chat_id, :string, null: false
      add :requested_action, :map, default: %{}, null: false
      add :rationale, :text
      add :status, :string, default: "pending", null: false
      add :decision_note, :text
      add :decided_at, :utc_datetime

      timestamps()
    end

    create index(:agent_approval_tasks, [:agent_id, :status, :inserted_at])
    create index(:agent_approval_tasks, [:thread_id, :status, :inserted_at])

    create table(:agent_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :integration_id, references(:agent_integrations, type: :binary_id, on_delete: :nilify_all)
      add :thread_id, references(:agent_event_threads, type: :binary_id, on_delete: :delete_all), null: false
      add :event_id, references(:agent_events, type: :binary_id, on_delete: :delete_all), null: false
      add :runbook_id, references(:agent_runbooks, type: :binary_id, on_delete: :nilify_all)
      add :trigger, :string, null: false
      add :mode, :string, null: false
      add :model, :string
      add :prompt_version, :string
      add :decision, :string
      add :audit_summary, :text
      add :tool_calls, :map, default: %{"items" => []}, null: false
      add :result, :map, default: %{}, null: false
      add :status, :string, default: "completed", null: false
      add :error, :text
      add :cost_usd, :decimal
      add :prompt_tokens, :integer
      add :completion_tokens, :integer

      timestamps()
    end

    create index(:agent_runs, [:agent_id, :inserted_at])
    create index(:agent_runs, [:thread_id, :inserted_at])
    create index(:agent_runs, [:status, :inserted_at])
  end
end
