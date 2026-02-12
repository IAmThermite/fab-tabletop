defmodule Tabletop.Repo do
  use Ecto.Repo,
    otp_app: :tabletop,
    adapter: Ecto.Adapters.Postgres
end
