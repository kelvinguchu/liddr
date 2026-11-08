defmodule Liddr.Ratings.RatingAction do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending rated skipped expired)
  @rater_roles ~w(rider driver)

  schema "ride_rating_actions" do
    field :ride_id, :id
    field :rated_by_user_id, :id
    field :rated_user_id, :id
    field :status, :string, default: "pending"
    field :rater_role, :string
    field :due_at, :utc_datetime_usec
    field :resolved_at, :utc_datetime_usec
    field :rating_id, :id
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(action, attrs) do
    action
    |> cast(attrs, [
      :ride_id,
      :rated_by_user_id,
      :rated_user_id,
      :status,
      :rater_role,
      :due_at,
      :resolved_at,
      :rating_id,
      :metadata
    ])
    |> validate_required([
      :ride_id,
      :rated_by_user_id,
      :rated_user_id,
      :status,
      :rater_role,
      :due_at
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:rater_role, @rater_roles)
    |> foreign_key_constraint(:ride_id)
    |> foreign_key_constraint(:rated_by_user_id)
    |> foreign_key_constraint(:rated_user_id)
    |> foreign_key_constraint(:rating_id)
    |> unique_constraint(:rated_by_user_id, name: :ride_rating_actions_unique_per_direction)
    |> check_constraint(:status, name: :ride_rating_actions_status_valid)
    |> check_constraint(:rater_role, name: :ride_rating_actions_rater_role_valid)
    |> check_constraint(:resolved_at, name: :ride_rating_actions_resolved_when_closed)
    |> check_constraint(:rated_by_user_id, name: :ride_rating_actions_rater_not_target)
  end
end
