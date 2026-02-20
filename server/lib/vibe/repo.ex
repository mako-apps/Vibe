defmodule Vibe.Repo do
  use Ecto.Repo,
    otp_app: :vibe,
    adapter: Ecto.Adapters.Postgres
end
