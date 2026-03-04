defmodule Liddr.Repo.Migrations.FixRideDestinationChangesDriverFk do
  use Ecto.Migration

  def up do
    alter table(:ride_destination_changes) do
      modify :driver_id,
             references(:drivers, column: :user_id, on_delete: :delete_all),
             null: false,
             from: references(:users, on_delete: :delete_all)
    end
  end

  def down do
    alter table(:ride_destination_changes) do
      modify :driver_id,
             references(:users, on_delete: :delete_all),
             null: false,
             from: references(:drivers, column: :user_id, on_delete: :delete_all)
    end
  end
end
