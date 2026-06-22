defmodule Vibe.AI.ToolRegistry do
  @moduledoc """
  Catalog of agent tools surfaced in agent config and used to validate the
  per-agent `enabled_tools` selection.

  Tools flagged `always_on: true` are part of the runtime regardless of the
  per-agent selection (see `Vibe.AI.Agent` @always_available_tool_names). They
  are listed here so the config UI can show them for transparency, but they are
  excluded from `default_tool_ids/0` and rendered as locked-on by clients.

  `category` lets clients group tools and lets operators assemble different tool
  sets per use case without hardcoding ids on the client.
  """

  @tools [
    %{
      id: "search_google",
      name: "Web Search",
      description: "Search the web for up-to-date information.",
      category: "research",
      always_on: false
    },
    %{
      id: "search_music",
      name: "Music Search",
      description: "Find tracks, albums, or artists with streaming links.",
      category: "research",
      always_on: false
    },
    %{
      id: "analyze_image",
      name: "Image Analysis",
      description: "Describe or inspect an image URL.",
      category: "research",
      always_on: false
    },
    %{
      id: "analyze_document",
      name: "Document Analysis",
      description: "Summarize or inspect a document URL.",
      category: "research",
      always_on: false
    },
    %{
      id: "create_document",
      name: "Create Document",
      description: "Create or replace a spreadsheet or document output.",
      category: "documents",
      always_on: false
    },
    %{
      id: "find_rows",
      name: "Find Rows",
      description: "Search spreadsheet rows before editing or exporting.",
      category: "documents",
      always_on: false
    },
    %{
      id: "edit_rows",
      name: "Edit Rows",
      description: "Update specific spreadsheet rows by index.",
      category: "documents",
      always_on: false
    },
    %{
      id: "delete_rows",
      name: "Delete Rows",
      description: "Delete spreadsheet rows by index.",
      category: "documents",
      always_on: false
    },
    %{
      id: "export_rows",
      name: "Export Rows",
      description: "Export spreadsheet data to PNG or PDF.",
      category: "documents",
      always_on: false
    },
    %{
      id: "delete_document",
      name: "Delete Document",
      description: "Delete the active generated document.",
      category: "documents",
      always_on: false
    },
    %{
      id: "call_connected_app",
      name: "Connected App & Live Data",
      description:
        "Call a configured connected app/analytics source for live website, business, or admin data and actions.",
      category: "data",
      always_on: false
    },
    %{
      id: "query_event_inbox",
      name: "Event Inbox & Analytics",
      description:
        "Query and aggregate the events this agent has received from its connected apps (counts, breakdowns, metric sums, notifications).",
      category: "analytics",
      always_on: true
    },
    %{
      id: "configure_event_inbox",
      name: "Inbox Delivery Settings",
      description: "Set how incoming events are delivered: per event or batched summaries (4h / daily).",
      category: "analytics",
      always_on: true
    }
  ]

  @doc "Full catalog including always-on tools (for display/config)."
  def tools, do: @tools

  @doc "Tools the user can toggle per agent (excludes always-on runtime tools)."
  def toggleable_tools, do: Enum.reject(@tools, & &1.always_on)

  @doc "Tools belonging to a category, e.g. \"analytics\" or \"documents\"."
  def tools_in_category(category) when is_binary(category) do
    Enum.filter(@tools, &(&1.category == category))
  end

  @doc "All known tool ids (toggleable + always-on)."
  def tool_ids, do: Enum.map(@tools, & &1.id)

  @doc "Toggleable tool ids only."
  def toggleable_tool_ids, do: Enum.map(toggleable_tools(), & &1.id)

  @doc "Default selection for a new agent: every toggleable tool."
  def default_tool_ids, do: toggleable_tool_ids()
end
