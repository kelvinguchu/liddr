defmodule Liddr.Repo.Migrations.AddRideGeofenceDistanceFields do
  use Ecto.Migration

  def change do
    alter table(:rides) do
      add :arrival_distance_m, :integer
      add :completion_distance_m, :integer
    end

    create constraint(:rides, :rides_arrival_distance_non_negative,
             check: "arrival_distance_m IS NULL OR arrival_distance_m >= 0"
           )

    create constraint(:rides, :rides_completion_distance_non_negative,
             check: "completion_distance_m IS NULL OR completion_distance_m >= 0"
           )
  end
end
