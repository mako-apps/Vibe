import Config

# Database config
config :vibe, Vibe.Repo,
  url: System.get_env("DATABASE_URL"),
  username: System.get_env("DB_USER") || "postgres",
  password: System.get_env("DB_PASS") || "postgres",
  hostname: System.get_env("DB_HOST") || "localhost",
  database: "vibe_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

# Endpoint config
config :vibe, VibeWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "DEV_SECRET_KEY_CHANGE_ME_IN_PROD_BUT_OK_FOR_DEV_Generate_With_mix_phx_gen_secret",
  watchers: []

config :logger, :runtime_prod,
  level: :info
