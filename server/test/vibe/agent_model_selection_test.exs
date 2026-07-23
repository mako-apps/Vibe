defmodule Vibe.AI.AgentModelSelectionTest do
  use ExUnit.Case, async: true

  alias Vibe.AI.AgentRuntime
  alias Vibe.AI.AgentRuntime.Config
  alias Vibe.AI.ModelRegistry

  test "publishes the supported providers and defaults new agents to Sonnet 5" do
    assert ModelRegistry.default_selection() == %{
             provider: "anthropic",
             model_id: "claude-sonnet-5"
           }

    payload = ModelRegistry.public_payload()

    assert payload.default == %{provider: "anthropic", modelId: "claude-sonnet-5"}

    assert Enum.map(payload.providers, & &1.id) == ["anthropic", "openai"]

    assert Enum.map(Enum.at(payload.providers, 0).models, & &1.id) == [
             "claude-fable-5",
             "claude-opus-4-8",
             "claude-sonnet-5",
             "claude-haiku-4-5-20251001"
           ]

    assert Enum.map(Enum.at(payload.providers, 1).models, & &1.id) == [
             "gpt-5.6-sol",
             "gpt-5.6-terra",
             "gpt-5.6-luna"
           ]
  end

  test "resolves complete and partial selections without accepting mismatched pairs" do
    assert {:ok, %{provider: "openai", model_id: "gpt-5.6-sol"}} =
             ModelRegistry.resolve_selection(%{"model_id" => "gpt-5.6-sol"})

    assert {:ok, %{provider: "openai", model_id: "gpt-5.6-luna"}} =
             ModelRegistry.resolve_selection(%{"modelProvider" => "openai"})

    assert {:ok, %{provider: "anthropic", model_id: "claude-opus-4-8"}} =
             ModelRegistry.resolve_selection(%{
               model_provider: "anthropic",
               model_id: "claude-opus-4-8"
             })

    assert {:error, :invalid_model_selection} =
             ModelRegistry.resolve_selection(%{
               "model_provider" => "anthropic",
               "model_id" => "gpt-5.6-terra"
             })

    assert {:error, :invalid_model_id} =
             ModelRegistry.resolve_selection(%{"model_id" => "not-a-model"})
  end

  test "keeps an existing agent selection when the update omits model fields" do
    assert {:ok, %{provider: "anthropic", model_id: "claude-haiku-4-5-20251001"}} =
             ModelRegistry.resolve_selection(
               %{"display_name" => "Renamed"},
               %{provider: "anthropic", model_id: "claude-haiku-4-5-20251001"}
             )
  end

  test "uses an explicitly selected OpenAI model instead of the fallback model" do
    config = %Config{
      provider: "openai",
      model: "gpt-5.6-sol",
      openai_fallback_model: "gpt-5.6-luna",
      system_prompt: "You are Vibe.",
      tools: [],
      execute_tools: fn _calls, state, _callback -> {[], state} end
    }

    payload = AgentRuntime.openai_request_payload([%{role: "user", content: "Hello"}], config)

    assert payload["model"] == "gpt-5.6-sol"
  end
end
