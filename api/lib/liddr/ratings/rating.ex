defmodule Liddr.Ratings.Rating do
  use Ecto.Schema
  import Ecto.Changeset

  schema "ride_ratings" do
    field :ride_id, :id
    field :rated_by_user_id, :id
    field :rated_user_id, :id
    field :score, :integer
    field :reason_tags, {:array, :string}, default: []
    field :comment, :string
    field :include_in_score, :boolean, default: true
    field :exclusion_reason_code, :string
    field :nullified_at, :utc_datetime_usec
    field :nullified_by_user_id, :id
    field :nullification_reason_code, :string
    field :nullification_note, :string
    field :submitted_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def create_changeset(rating, attrs) do
    rating
    |> cast(attrs, [
      :ride_id,
      :rated_by_user_id,
      :rated_user_id,
      :score,
      :reason_tags,
      :comment,
      :include_in_score,
      :exclusion_reason_code,
      :nullified_at,
      :nullified_by_user_id,
      :nullification_reason_code,
      :nullification_note,
      :submitted_at,
      :metadata
    ])
    |> validate_required([:ride_id, :rated_by_user_id, :rated_user_id, :score, :submitted_at])
    |> validate_number(:score, greater_than_or_equal_to: 1, less_than_or_equal_to: 5)
    |> validate_length(:comment, max: 200)
    |> foreign_key_constraint(:ride_id)
    |> foreign_key_constraint(:rated_by_user_id)
    |> foreign_key_constraint(:rated_user_id)
    |> foreign_key_constraint(:nullified_by_user_id)
    |> unique_constraint(:rated_by_user_id, name: :ride_ratings_unique_per_direction)
    |> check_constraint(:score, name: :ride_ratings_score_range)
    |> check_constraint(:rated_by_user_id, name: :ride_ratings_rater_not_target)
    |> check_constraint(:nullification_reason_code,
      name: :ride_ratings_nullification_reason_required
    )
  end
end
