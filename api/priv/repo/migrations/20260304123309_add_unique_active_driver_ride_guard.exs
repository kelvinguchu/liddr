defmodule Liddr.Repo.Migrations.AddUniqueActiveDriverRideGuard do
  use Ecto.Migration

  def change do
    create unique_index(:rides, [:driver_id],
             where:
               "driver_id IS NOT NULL AND status IN ('accepted', 'driver_arriving', 'arrived', 'in_progress')",
             name: :rides_unique_active_driver_idx
           )
  end
end
