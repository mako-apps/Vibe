defmodule VibeWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.
  """
  use Phoenix.Component

  # Minimal implementation to satisfy interface
  slot :inner_block, required: true
  def flash_group(assigns) do
    ~H"""
    <div><%= render_slot(@inner_block) %></div>
    """
  end
end
