defmodule Liddr.Repo.Migrations.AddProhibitedItemsForSend do
  use Ecto.Migration

  def change do
    create table(:prohibited_items) do
      add :keyword, :string, null: false
      add :severity, :string, null: false, default: "block"
      add :message, :string
      add :is_active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:prohibited_items, [:keyword])
    create index(:prohibited_items, [:is_active, :severity])

    create constraint(
             :prohibited_items,
             :prohibited_items_severity_valid,
             check: "severity IN ('warn', 'block')"
           )
  end
end
