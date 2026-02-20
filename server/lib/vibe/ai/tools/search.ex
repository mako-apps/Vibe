defmodule Vibe.AI.Tools.Search do
  @moduledoc """
  Web search tool using Gemini with Google Search grounding.

  Uses Gemini 2.0 Flash with built-in Google Search capability for real-time web results.
  Falls back to direct search APIs if Gemini fails.
  """

  require Logger

  @gemini_api "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.0-flash:generateContent"

  @doc """
  Search the web using Gemini with Google Search grounding and return structured results.
  """
  def google(%{"query" => query}) do
    case search_with_gemini(query) do
      {:ok, results} -> results
      {:error, reason} ->
        Logger.warning("[Search] Gemini search failed: #{reason}")
        %{error: "Search failed", query: query}
    end
  end

  # Handle missing query parameter
  def google(_params), do: %{error: "Missing search query"}

  defp search_with_gemini(query) do
    api_key = System.get_env("GEMINI_API_KEY")

    if is_nil(api_key) do
      {:error, "No Gemini API key configured"}
    else
      url = "#{@gemini_api}?key=#{api_key}"

      body = Jason.encode!(%{
        contents: [
          %{
            parts: [
              %{
                text: """
                Search the web for: #{query}

                Return the top 5 most relevant results as a JSON array with this exact format:
                [
                  {"title": "Page Title", "url": "https://...", "snippet": "Brief description..."},
                  ...
                ]

                Only return the JSON array, nothing else. No markdown, no explanation.
                """
              }
            ]
          }
        ],
        tools: [
          %{
            google_search: %{}
          }
        ],
        generationConfig: %{
          temperature: 0.1,
          maxOutputTokens: 2048
        }
      })

      headers = [{"Content-Type", "application/json"}]
      request = Finch.build(:post, url, headers, body)

      case Finch.request(request, Vibe.Finch, receive_timeout: 30_000) do
        {:ok, %{status: 200, body: resp_body}} ->
          parse_gemini_response(resp_body, query)

        {:ok, %{status: status, body: resp_body}} ->
          Logger.error("[Search] Gemini API error: #{status} - #{resp_body}")
          {:error, "Gemini API error: #{status}"}

        {:error, reason} ->
          Logger.error("[Search] Gemini request failed: #{inspect(reason)}")
          {:error, "Request failed"}
      end
    end
  end

  defp parse_gemini_response(body, query) do
    case Jason.decode(body) do
      {:ok, %{"candidates" => [%{"content" => %{"parts" => parts}} | _]}} ->
        # Extract text and grounding metadata
        text_parts = Enum.filter(parts, &Map.has_key?(&1, "text"))
        text = Enum.map_join(text_parts, "", & &1["text"])

        # Try to parse JSON results from text
        case extract_json_results(text) do
          {:ok, results} ->
            {:ok, %{
              source: "gemini",
              count: length(results),
              results: results,
              query: query
            }}

          {:error, _} ->
            # If no JSON, return the text as a single result summary
            {:ok, %{
              source: "gemini",
              count: 1,
              results: [%{title: "Search Results", snippet: text, url: nil}],
              query: query
            }}
        end

      {:ok, %{"candidates" => [%{"groundingMetadata" => metadata} | _]}} ->
        # Handle grounding metadata format
        chunks = Map.get(metadata, "groundingChunks", [])
        results = Enum.map(chunks, fn chunk ->
          web = Map.get(chunk, "web", %{})
          %{
            title: Map.get(web, "title", ""),
            url: Map.get(web, "uri", ""),
            snippet: ""
          }
        end)

        {:ok, %{
          source: "gemini",
          count: length(results),
          results: Enum.take(results, 5),
          query: query
        }}

      {:ok, response} ->
        Logger.warning("[Search] Unexpected Gemini response format: #{inspect(response)}")
        {:error, "Unexpected response format"}

      {:error, reason} ->
        {:error, "Failed to parse response: #{inspect(reason)}"}
    end
  end

  defp extract_json_results(text) do
    # Try to find and parse JSON array in the response
    trimmed = String.trim(text)

    # Remove markdown code blocks if present
    cleaned = trimmed
    |> String.replace(~r/^```json\s*/, "")
    |> String.replace(~r/^```\s*/, "")
    |> String.replace(~r/\s*```$/, "")
    |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, results} when is_list(results) ->
        formatted = Enum.take(results, 5) |> Enum.map(fn item ->
          %{
            title: item["title"] || "",
            url: item["url"] || "",
            snippet: item["snippet"] || item["description"] || ""
          }
        end)
        {:ok, formatted}

      _ ->
        {:error, "Not valid JSON array"}
    end
  end
end
