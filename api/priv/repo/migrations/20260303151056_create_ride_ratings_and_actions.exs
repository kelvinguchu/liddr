defmodule Liddr.Repo.Migrations.CreateRideRatingsAndActions do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :rating_weight_total, :decimal, precision: 14, scale: 6, null: false, default: 0
    end

    create constraint(:users, :users_rating_weight_total_non_negative,
             check: "rating_weight_total >= 0"
           )

    create table(:ride_ratings) do
      add :ride_id, references(:rides, on_delete: :delete_all), null: false
      add :rated_by_user_id, references(:users, on_delete: :restrict), null: false
      add :rated_user_id, references(:users, on_delete: :restrict), null: false
      add :score, :integer, null: false
      add :reason_tags, {:array, :string}, null: false, default: []
      add :comment, :text
      add :include_in_score, :boolean, null: false, default: true
      add :exclusion_reason_code, :string
      add :submitted_at, :utc_datetime_usec, null: false
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:ride_ratings, [:ride_id, :rated_by_user_id],
             name: :ride_ratings_unique_per_direction
           )

    create index(:ride_ratings, [:rated_user_id, :submitted_at])
    create index(:ride_ratings, [:rated_by_user_id, :submitted_at])
    create index(:ride_ratings, [:include_in_score, :submitted_at])

    create constraint(:ride_ratings, :ride_ratings_score_range,
             check: "score >= 1 AND score <= 5"
           )

    create constraint(:ride_ratings, :ride_ratings_rater_not_target,
             check: "rated_by_user_id <> rated_user_id"
           )

    create table(:ride_rating_actions) do
      add :ride_id, references(:rides, on_delete: :delete_all), null: false
      add :rated_by_user_id, references(:users, on_delete: :restrict), null: false
      add :rated_user_id, references(:users, on_delete: :restrict), null: false
      add :status, :string, null: false, default: "pending"
      add :rater_role, :string, null: false
      add :due_at, :utc_datetime_usec, null: false
      add :resolved_at, :utc_datetime_usec
      add :rating_id, references(:ride_ratings, on_delete: :nilify_all)
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:ride_rating_actions, [:ride_id, :rated_by_user_id],
             name: :ride_rating_actions_unique_per_direction
           )

    create index(:ride_rating_actions, [:rated_by_user_id, :status, :due_at])
    create index(:ride_rating_actions, [:status, :due_at])

    create constraint(:ride_rating_actions, :ride_rating_actions_status_valid,
             check: "status IN ('pending', 'rated', 'skipped', 'expired')"
           )

    create constraint(:ride_rating_actions, :ride_rating_actions_rater_role_valid,
             check: "rater_role IN ('rider', 'driver')"
           )

    create constraint(:ride_rating_actions, :ride_rating_actions_resolved_when_closed,
             check: "status = 'pending' OR resolved_at IS NOT NULL"
           )

    create constraint(:ride_rating_actions, :ride_rating_actions_rater_not_target,
             check: "rated_by_user_id <> rated_user_id"
           )
  end
end
