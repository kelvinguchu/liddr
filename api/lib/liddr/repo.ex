defmodule Liddr.Repo do
  use Ecto.Repo,
    otp_app: :liddr,
    adapter: Ecto.Adapters.Postgres
end
