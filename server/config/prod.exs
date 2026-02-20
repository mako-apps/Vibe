import Config

# Note: We configure the endpoint for production here, but
# most configuration is done in runtime.exs (which is loaded
# by `mix release`).

config :vibe, VibeWeb.Endpoint,
  url: [host: "example.com", port: 80]

# Do not print debug messages in production
config :logger, level: :info
