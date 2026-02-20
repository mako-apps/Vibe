defmodule Vibe.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Create ETS table for rate limiting before starting the endpoint
    # This must happen before any requests can hit the RateLimiter plug
    :ets.new(:rate_limiter, [:set, :public, :named_table, {:read_concurrency, true}])

    children = [
      # Start the Telemetry supervisor
      # VibeWeb.Telemetry,
      # Start the Ecto repository
      Vibe.Repo,
      # Start the PubSub system
      {Phoenix.PubSub, name: Vibe.PubSub},
      # Start Presence tracking
      VibeWeb.Presence,
      # Start Finch HTTP client for AI APIs
      {Finch, name: Vibe.Finch},
      # Start the Endpoint (http/https)
      VibeWeb.Endpoint,
      # Start the Relay Registry (VibeNet peer relay network)
      Vibe.RelayRegistry,
      # Start the scheduled post scheduler
      # Start the scheduled post scheduler
      Vibe.Scheduler,
      # Start the Story Cleaner
      Vibe.StoryCleaner
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Vibe.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    VibeWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
