defmodule Liddr.Repo.Migrations.RemoveLegacyUserRoleColumn do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE users DROP CONSTRAINT IF EXISTS users_role_valid")

    alter table(:users) do
      remove :role
    end
  end

  def down do
    alter table(:users) do
      add :role, :string, null: false, default: "passenger"
    end

    create constraint(:users, :users_role_valid,
             check: "role IN ('driver', 'passenger', 'ops', 'admin')"
           )
  end
end
