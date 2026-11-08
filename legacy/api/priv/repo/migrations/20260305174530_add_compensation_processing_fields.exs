defmodule Liddr.Repo.Migrations.AddCompensationProcessingFields do
  use Ecto.Migration

  def change do
    alter table(:dispute_compensations) do
      add :processed_at, :utc_datetime_usec
      add :processed_by_user_id, references(:users, on_delete: :nilify_all)
    end

    create index(:dispute_compensations, [:processed_by_user_id, :processed_at])

    create constraint(:dispute_compensations, :dispute_compensations_processed_presence,
             check:
               "(status = 'approved' AND processed_at IS NULL) OR (status IN ('paid', 'cancelled') AND processed_at IS NOT NULL)"
           )
  end
end
