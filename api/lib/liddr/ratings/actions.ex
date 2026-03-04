defmodule Liddr.Ratings.Actions do
  import Ecto.Query

  alias Liddr.Ratings.Policy
  alias Liddr.Ratings.RatingAction
  alias Liddr.Repo

  @pending_status "pending"

  def enqueue_for_completed_ride!(ride, now) do
    due_at = Policy.due_at(now)

    action_rows = [
      %{
        ride_id: ride.id,
        rated_by_user_id: ride.rider_id,
        rated_user_id: ride.driver_id,
        status: @pending_status,
        rater_role: "rider",
        due_at: due_at,
        inserted_at: now,
        updated_at: now,
        metadata: %{}
      },
      %{
        ride_id: ride.id,
        rated_by_user_id: ride.driver_id,
        rated_user_id: ride.rider_id,
        status: @pending_status,
        rater_role: "driver",
        due_at: due_at,
        inserted_at: now,
        updated_at: now,
        metadata: %{}
      }
    ]

    {count, _} =
      Repo.insert_all(
        RatingAction,
        action_rows,
        on_conflict: :nothing,
        conflict_target: [:ride_id, :rated_by_user_id]
      )

    %{count: count, due_at: due_at}
  end

  def list_pending_for_user(user_id, now) do
    expire_due_actions(user_id, now)

    Repo.all(
      from a in RatingAction,
        join: r in "rides",
        on: r.id == a.ride_id,
        where: a.rated_by_user_id == ^user_id and a.status == @pending_status and a.due_at > ^now,
        order_by: [asc: a.due_at, asc: a.id],
        select: %{
          action_id: a.id,
          ride_id: a.ride_id,
          rated_user_id: a.rated_user_id,
          rater_role: a.rater_role,
          due_at: a.due_at,
          completed_at: field(r, :completed_at)
        }
    )
  end

  def fetch_pending_action_for_update!(ride_id, rated_by_user_id, now) do
    expire_due_actions(rated_by_user_id, now)

    Repo.one(
      from a in RatingAction,
        where:
          a.ride_id == ^ride_id and a.rated_by_user_id == ^rated_by_user_id and
            a.status == @pending_status and a.due_at > ^now,
        lock: "FOR UPDATE"
    ) || Repo.rollback(:rating_action_not_pending)
  end

  def mark_rated!(action, rating_id, now) do
    action
    |> RatingAction.create_changeset(%{
      "status" => "rated",
      "rating_id" => rating_id,
      "resolved_at" => now
    })
    |> Repo.update()
    |> unwrap_or_rollback()
  end

  def mark_skipped!(action, now) do
    action
    |> RatingAction.create_changeset(%{
      "status" => "skipped",
      "resolved_at" => now
    })
    |> Repo.update()
    |> unwrap_or_rollback()
  end

  defp expire_due_actions(user_id, now) do
    Repo.update_all(
      from(a in RatingAction,
        where: a.rated_by_user_id == ^user_id and a.status == @pending_status and a.due_at <= ^now
      ),
      set: [status: "expired", resolved_at: now, updated_at: now]
    )
  end

  defp unwrap_or_rollback({:ok, value}), do: value
  defp unwrap_or_rollback({:error, changeset}), do: Repo.rollback(changeset)
end
