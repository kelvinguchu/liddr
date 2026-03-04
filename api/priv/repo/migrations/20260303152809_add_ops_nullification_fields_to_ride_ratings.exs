defmodule Liddr.Repo.Migrations.AddOpsNullificationFieldsToRideRatings do
  use Ecto.Migration

  def change do
    alter table(:ride_ratings) do
      add :nullified_at, :utc_datetime_usec
      add :nullified_by_user_id, references(:users, on_delete: :nilify_all)
      add :nullification_reason_code, :string
      add :nullification_note, :text
    end

    create index(:ride_ratings, [:nullified_at, :nullified_by_user_id])

    create constraint(:ride_ratings, :ride_ratings_nullification_reason_required,
             check: "nullified_at IS NULL OR nullification_reason_code IS NOT NULL"
           )
  end
end
