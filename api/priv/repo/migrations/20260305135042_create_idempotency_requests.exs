defmodule Liddr.Repo.Migrations.CreateIdempotencyRequests do
  use Ecto.Migration

  def change do
    create table(:idempotency_requests) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :operation, :string, null: false
      add :idempotency_key, :string, null: false
      add :request_hash, :string, null: false
      add :response_status, :integer
      add :response_body, :map
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :idempotency_requests,
             [:user_id, :operation, :idempotency_key],
             name: :idempotency_requests_unique_user_operation_key
           )

    create index(:idempotency_requests, [:inserted_at])
  end
end
