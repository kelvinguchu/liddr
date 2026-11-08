defmodule Liddr.Repo.Migrations.AddAuthChallengeRateLimitIndexes do
  use Ecto.Migration

  def change do
    create index(:auth_challenges, [:provider, :identity_value, :inserted_at])

    create index(:auth_challenges, [:requested_by_ip, :inserted_at],
             where: "requested_by_ip IS NOT NULL"
           )

    create index(:auth_challenges, [:requested_by_device, :inserted_at],
             where: "requested_by_device IS NOT NULL"
           )
  end
end
