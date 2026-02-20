defmodule Vibe.AI.ImageEditor do
  @moduledoc """
  Handles AI image editing using Gemini API (Nano Banana Pro / Gemini 3).
  """

  require Logger
  alias Vibe.AI.Tools.Vision

  # Using Gemini 3.0 Pro Image Preview (Nano Banana Pro)
  @gemini_api "https://generativelanguage.googleapis.com/v1beta/models/gemini-3-pro-image-preview:generateContent"
  @uploads_dir "/app/uploads"

  @doc """
  Edits an image based on a prompt using Nano Banana Pro.
  """
  def edit_image(image_url, prompt) do
    # Truncate for logging if it's a data URL
    log_url = if String.starts_with?(image_url, "data:") do
      "data:image/...;base64,[#{String.length(image_url)} chars]"
    else
      image_url
    end
    Logger.info("[ImageEditor] Editing image: #{log_url} with prompt: '#{prompt}'")

    api_key = System.get_env("GEMINI_API_KEY")

    if is_nil(api_key) do
      {:error, "No Gemini API key configured"}
    else
      # Check if already a data URL (base64), otherwise fetch and encode
      case get_base64_data_url(image_url) do
        {:ok, base64_data_url} ->
          call_gemini_edit(api_key, base64_data_url, prompt)

        {:error, reason} ->
          {:error, "Failed to process image: #{reason}"}
      end
    end
  end

  # If already a data URL, use it directly
  defp get_base64_data_url(url) when is_binary(url) do
    cond do
      String.starts_with?(url, "data:image/") ->
        {:ok, url}
      String.starts_with?(url, "http") ->
        Vision.fetch_and_encode(url)
      true ->
        {:error, "Invalid image URL format"}
    end
  end

  defp call_gemini_edit(api_key, base64_data_url, prompt) do
    [header, data] = String.split(base64_data_url, ";base64,")
    mime_type = String.replace(header, "data:", "")

    url = "#{@gemini_api}?key=#{api_key}"

    body = Jason.encode!(%{
      contents: [%{
        parts: [
          %{
            text: "Edit this image: #{prompt}. Return the edited image."
          },
          %{
            inline_data: %{
              mime_type: mime_type,
              data: data
            }
          }
        ]
      }],
      generationConfig: %{
        temperature: 0.4,
        maxOutputTokens: 2048
      }
    })

    headers = [{"Content-Type", "application/json"}]
    request = Finch.build(:post, url, headers, body)

    case Finch.request(request, Vibe.Finch, receive_timeout: 60_000) do
      {:ok, %{status: 200, body: resp_body}} ->
        Logger.info("[ImageEditor] Gemini Raw Response Length: #{byte_size(resp_body)}")
        Logger.info("[ImageEditor] Response Head: #{String.slice(resp_body, 0, 1000)}")

        case Jason.decode(resp_body) do
          {:ok, %{"candidates" => [%{"content" => %{"parts" => parts}} | _]}} ->
             # Debug parts
             Logger.info("[ImageEditor] Parts count: #{length(parts)}")
             Enum.each(parts, fn p -> Logger.info("Part keys: #{inspect(Map.keys(p))}") end)

             # 1. Look for inline_data text: inlineData
             image_part = Enum.find(parts, fn part ->
               Map.has_key?(part, "inline_data") or Map.has_key?(part, "inlineData")
             end)

             if image_part do
               # Extract data whether it's snake_case or camelCase
               data_obj = image_part["inline_data"] || image_part["inlineData"]

               mime = data_obj["mime_type"] || data_obj["mimeType"]
               data = data_obj["data"]
               save_generated_image(data, mime)
             else
               # 2. Fallback: Check if text contains base64
               text = Enum.map_join(parts, "", &(&1["text"] || ""))

               if String.contains?(text, "data:image/") do
                  case Regex.run(~r/data:image\/(\w+);base64,([a-zA-Z0-9+\/=]+)/, text) do
                    [_, ext, b64] -> save_generated_image(b64, "image/#{ext}")
                    _ -> {:error, "Could not extract image from response"}
                  end
               else
                  {:error, "No image generated. Model said: #{String.slice(text, 0, 100)}"}
               end
             end

          other ->
             Logger.error("[ImageEditor] Parsing failed: #{inspect(other)}")
             {:error, "Failed to parse Gemini response"}
        end

      {:ok, %{status: status, body: body}} ->
        Logger.error("[ImageEditor] Gemini API error: #{status} - #{body}")
        {:error, "API error: #{status}"}

      {:error, reason} ->
        Logger.error("[ImageEditor] Request failed: #{inspect(reason)}")
        {:error, "Request failed"}
    end
  end

  defp save_generated_image(base64_data, mime_type) do
    # Ensure uploads dir exists
    File.mkdir_p!(@uploads_dir)

    # Determine extension
    ext = case mime_type do
      "image/jpeg" -> ".jpg"
      "image/png" -> ".png"
      "image/webp" -> ".webp"
      _ -> ".jpg"
    end

    filename = "ai_edit_#{Ecto.UUID.generate()}#{ext}"
    path = Path.join(@uploads_dir, filename)

    case Base.decode64(base64_data, ignore: :whitespace) do
      {:ok, binary} ->
        File.write!(path, binary)

        # Return URL relative to /uploads mount (served by Endpoint)
        {:ok, "/uploads/#{filename}"}

      :error ->
        {:error, "Failed to decode generated image"}
    end
  end
end
