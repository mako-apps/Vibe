defmodule VibeWeb.AIController do
  @moduledoc """
  Controller for AI-specific endpoints like image editing.
  """
  use VibeWeb, :controller
  alias Vibe.AI.ImageEditor

  require Logger

  @doc """
  Edit an image using AI.
  POST /api/ai/edit_image
  Body: { "image_url": "...", "prompt": "..." }
  """
  def edit_image(conn, %{"image_url" => image_url, "prompt" => prompt})
      when is_binary(image_url) and is_binary(prompt) and byte_size(prompt) > 0 do
    Logger.info("[AIController] edit_image called with prompt: #{String.slice(prompt, 0, 50)}...")

    case ImageEditor.edit_image(image_url, prompt) do
      {:ok, edited_url} ->
        json(conn, %{success: true, url: edited_url})

      {:error, reason} ->
        Logger.error("[AIController] edit_image failed: #{inspect(reason)}")
        conn
        |> put_status(:bad_request)
        |> json(%{success: false, error: "Failed to edit image", details: inspect(reason)})
    end
  end

  def edit_image(conn, params) do
    Logger.warning("[AIController] edit_image called with invalid params: #{inspect(params)}")

    missing =
      []
      |> then(fn acc -> if Map.has_key?(params, "image_url"), do: acc, else: ["image_url" | acc] end)
      |> then(fn acc -> if Map.has_key?(params, "prompt"), do: acc, else: ["prompt" | acc] end)

    conn
    |> put_status(:bad_request)
    |> json(%{
      success: false,
      error: "Missing or invalid parameters",
      details: if(missing != [], do: "Missing: #{Enum.join(missing, ", ")}", else: "prompt cannot be empty")
    })
  end
end
