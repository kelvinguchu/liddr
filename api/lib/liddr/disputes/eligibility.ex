defmodule Liddr.Disputes.Eligibility do
  @moduledoc false

  import Ecto.Query

  alias Liddr.Moderation.Report
  alias Liddr.Repo
  alias Liddr.Rides.Ride

  @submission_window_seconds 48 * 60 * 60
  @week_seconds 7 * 24 * 60 * 60
  @max_disputes_per_ride 3
  @max_disputes_per_week 10
  @active_statuses ~w(accepted driver_arriving arrived in_progress)
  @ended_statuses ~w(completed cancelled)
  @active_ride_dispute_types ~w(safety_incident wrong_driver)

  def check(%Ride{} = ride, dispute_type, reporter_user_id, now \\ DateTime.utc_now()) do
    with :ok <- ensure_ride_state(ride, dispute_type, now),
         :ok <- ensure_ride_limit(ride.id, reporter_user_id) do
      ensure_weekly_limit(reporter_user_id, now)
    end
  end

  defp ensure_ride_state(%Ride{status: status}, dispute_type, _now)
       when status in @active_statuses and dispute_type in @active_ride_dispute_types,
       do: :ok

  defp ensure_ride_state(%Ride{status: status} = ride, _dispute_type, now)
       when status in @ended_statuses do
    case ride.completed_at || ride.cancelled_at do
      %DateTime{} = ended_at -> ensure_within_window(ended_at, now)
      _ -> {:error, :dispute_ride_not_eligible}
    end
  end

  defp ensure_ride_state(_ride, _dispute_type, _now), do: {:error, :dispute_ride_not_eligible}

  defp ensure_within_window(ended_at, now) do
    if DateTime.diff(now, ended_at, :second) > @submission_window_seconds,
      do: {:error, :dispute_window_closed},
      else: :ok
  end

  defp ensure_ride_limit(ride_id, reporter_user_id) do
    context_reference = Integer.to_string(ride_id)

    count =
      reporter_user_id
      |> reporter_disputes()
      |> where([r], r.context_reference == ^context_reference)
      |> Repo.aggregate(:count, :id)

    if count >= @max_disputes_per_ride, do: {:error, :dispute_ride_limit_reached}, else: :ok
  end

  defp ensure_weekly_limit(reporter_user_id, now) do
    cutoff = DateTime.add(now, -@week_seconds, :second)

    count =
      reporter_user_id
      |> reporter_disputes()
      |> where([r], r.inserted_at >= ^cutoff)
      |> Repo.aggregate(:count, :id)

    if count >= @max_disputes_per_week, do: {:error, :dispute_weekly_limit_reached}, else: :ok
  end

  defp reporter_disputes(reporter_user_id) do
    from r in Report,
      where:
        r.reporter_user_id == ^reporter_user_id and r.context_type == "ride" and
          fragment("? ->> 'dispute_type' IS NOT NULL", r.metadata)
  end
end
