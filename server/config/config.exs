import Config

config :vibe,
  ecto_repos: [Vibe.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configures the endpoint
config :vibe, VibeWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Phoenix.Endpoint.Cowboy2Adapter,
  render_errors: [
    formats: [json: VibeWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Vibe.PubSub,
  live_view: [signing_salt: "SECRET_SALT_CHANGE_ME"]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
