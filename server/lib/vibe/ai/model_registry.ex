defmodule Vibe.AI.ModelRegistry do
  @moduledoc false

  @default %{provider: "anthropic", model_id: "claude-sonnet-5"}

  @providers [
    %{
      id: "anthropic",
      name: "Anthropic",
      default_model_id: "claude-sonnet-5",
      models: [
        %{
          id: "claude-fable-5",
          name: "Claude Fable 5",
          description: "Deep reasoning for the most demanding agent tasks.",
          tier: "max",
          recommended: false
        },
        %{
          id: "claude-opus-4-8",
          name: "Claude Opus 4.8",
          description: "High-capability reasoning for complex work.",
          tier: "premium",
          recommended: false
        },
        %{
          id: "claude-sonnet-5",
          name: "Claude Sonnet 5",
          description: "The recommended balance of intelligence, speed, and cost.",
          tier: "balanced",
          recommended: true
        },
        %{
          id: "claude-haiku-4-5-20251001",
          name: "Claude Haiku 4.5",
          description: "Fast, economical responses for lightweight tasks.",
          tier: "fast",
          recommended: false
        }
      ]
    },
    %{
      id: "openai",
      name: "OpenAI",
      default_model_id: "gpt-5.6-luna",
      models: [
        %{
          id: "gpt-5.6-sol",
          name: "GPT-5.6 Sol",
          description: "Maximum capability for complex agent workflows.",
          tier: "max",
          recommended: false
        },
        %{
          id: "gpt-5.6-terra",
          name: "GPT-5.6 Terra",
          description: "Balanced capability for everyday agent work.",
          tier: "balanced",
          recommended: false
        },
        %{
          id: "gpt-5.6-luna",
          name: "GPT-5.6 Luna",
          description: "Fast, cost-efficient responses.",
          tier: "fast",
          recommended: true
        }
      ]
    }
  ]

  def default_selection, do: @default

  def providers, do: @providers

  def provider_ids, do: Enum.map(@providers, & &1.id)

  def public_payload do
    %{
      default: %{provider: @default.provider, modelId: @default.model_id},
      providers:
        Enum.map(@providers, fn provider ->
          %{
            id: provider.id,
            name: provider.name,
            available: provider_available?(provider.id),
            models: provider.models
          }
        end)
    }
  end

  def provider_for_model(model_id) when is_binary(model_id) do
    normalized = String.trim(model_id)

    case Enum.find(@providers, fn provider ->
           Enum.any?(provider.models, &(&1.id == normalized))
         end) do
      nil -> nil
      provider -> provider.id
    end
  end

  def provider_for_model(_model_id), do: nil

  def valid_selection?(provider, model_id) when is_binary(provider) and is_binary(model_id) do
    normalized_provider = String.trim(provider)
    normalized_model = String.trim(model_id)

    Enum.any?(@providers, fn candidate ->
      candidate.id == normalized_provider and
        Enum.any?(candidate.models, &(&1.id == normalized_model))
    end)
  end

  def valid_selection?(_provider, _model_id), do: false

  def resolve_selection(attrs, current \\ @default) when is_map(attrs) do
    provider_input =
      fetch_input(attrs, ["model_provider", :model_provider, "modelProvider", :modelProvider])

    model_input = fetch_input(attrs, ["model_id", :model_id, "modelId", :modelId])
    current = normalize_current(current)

    case {provider_input, model_input} do
      {:missing, :missing} ->
        {:ok, current}

      {{:present, provider}, :missing} ->
        with {:ok, provider} <- normalize_provider(provider),
             {:ok, model_id} <- default_model_for_provider(provider) do
          {:ok, %{provider: provider, model_id: model_id}}
        end

      {:missing, {:present, model_id}} ->
        with {:ok, model_id} <- normalize_model(model_id),
             provider when is_binary(provider) <- provider_for_model(model_id) do
          {:ok, %{provider: provider, model_id: model_id}}
        else
          _ -> {:error, :invalid_model_id}
        end

      {{:present, provider}, {:present, model_id}} ->
        with {:ok, provider} <- normalize_provider(provider),
             {:ok, model_id} <- normalize_model(model_id),
             true <- valid_selection?(provider, model_id) do
          {:ok, %{provider: provider, model_id: model_id}}
        else
          {:error, reason} -> {:error, reason}
          false -> {:error, :invalid_model_selection}
        end
    end
  end

  def provider_available?("anthropic") do
    configured?("ANTHROPIC_API_KEY") or configured?("CLAUDE_API_KEY")
  end

  def provider_available?("openai"), do: configured?("OPENAI_API_KEY")
  def provider_available?(_provider), do: false

  defp normalize_current(%{provider: provider, model_id: model_id}) do
    if valid_selection?(provider, model_id),
      do: %{provider: provider, model_id: model_id},
      else: @default
  end

  defp normalize_current(%{"provider" => provider, "model_id" => model_id}) do
    normalize_current(%{provider: provider, model_id: model_id})
  end

  defp normalize_current(_current), do: @default

  defp normalize_provider(value) when is_binary(value) do
    provider = value |> String.trim() |> String.downcase()
    if provider in provider_ids(), do: {:ok, provider}, else: {:error, :invalid_model_provider}
  end

  defp normalize_provider(_value), do: {:error, :invalid_model_provider}

  defp normalize_model(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :invalid_model_id}
      model_id -> {:ok, model_id}
    end
  end

  defp normalize_model(_value), do: {:error, :invalid_model_id}

  defp default_model_for_provider(provider) do
    case Enum.find(@providers, &(&1.id == provider)) do
      nil -> {:error, :invalid_model_provider}
      entry -> {:ok, entry.default_model_id}
    end
  end

  defp fetch_input(attrs, keys) do
    Enum.find_value(keys, :missing, fn key ->
      if Map.has_key?(attrs, key), do: {:present, Map.get(attrs, key)}
    end)
  end

  defp configured?(name) do
    case System.get_env(name) do
      value when is_binary(value) -> String.trim(value) != ""
      _ -> false
    end
  end
end
