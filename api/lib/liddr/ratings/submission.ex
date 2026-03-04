defmodule Liddr.Ratings.Submission do
  import Ecto.Query

  alias Liddr.Repo
  alias Liddr.Ratings.Actions
  alias Liddr.Ratings.AbuseSignals
  alias Liddr.Ratings.EnforcementSignals
  alias Liddr.Ratings.Inclusion
  alias Liddr.Ratings.Rating
  alias Liddr.Ratings.Scoring
  alias Liddr.Rides.Events
  alias Liddr.Rides.Realtime
  alias Liddr.Rides.Ride
  alias Liddr.Subscriptions.PaymentUtils

  def rate_ride(rated_by_user_id, ride_id, attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    parsed_ride_id = parse_positive_integer(ride_id) || {:error, :ride_not_found}

    with ride_id when is_integer(ride_id) <- parsed_ride_id do
      Repo.transaction(fn ->
        ride = fetch_completed_ride_for_update!(ride_id)
        ensure_rater_participated!(ride, rated_by_user_id)
        action = Actions.fetch_pending_action_for_update!(ride.id, rated_by_user_id, now)
        score = parse_score!(attrs)
        reason_tags = parse_reason_tags(attrs)
        validate_reason_tags!(score, reason_tags)

        {include_in_score, exclusion_reason_code} = Inclusion.decision(score, reason_tags)

        rating =
          %Rating{}
          |> Rating.create_changeset(%{
            "ride_id" => ride.id,
            "rated_by_user_id" => rated_by_user_id,
            "rated_user_id" => action.rated_user_id,
            "score" => score,
            "reason_tags" => reason_tags,
            "comment" => parse_comment(attrs),
            "include_in_score" => include_in_score,
            "exclusion_reason_code" => exclusion_reason_code,
            "submitted_at" => now,
            "metadata" => %{"source" => "ride_rating_v1"}
          })
          |> Repo.insert()
          |> unwrap_or_rollback()

        _ = Actions.mark_rated!(action, rating.id, now)
        stats = Scoring.recalculate_user_score!(rating.rated_user_id, now)

        _ =
          Events.record_event(ride.id, "ride_rated", now,
            actor_user_id: rated_by_user_id,
            payload: %{
              "rating_id" => rating.id,
              "score" => score,
              "include_in_score" => include_in_score,
              "exclusion_reason_code" => exclusion_reason_code
            }
          )
          |> unwrap_or_rollback()

        %{
          rating: rating,
          rating_action_status: "rated",
          rated_user_stats: stats,
          ride_id: ride.id,
          driver_id: ride.driver_id
        }
      end)
      |> unwrap_transaction_result()
      |> maybe_broadcast_rating_submitted()
    else
      _ -> {:error, :ride_not_found}
    end
  end

  def skip_ride_rating(rated_by_user_id, ride_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    parsed_ride_id = parse_positive_integer(ride_id) || {:error, :ride_not_found}

    with ride_id when is_integer(ride_id) <- parsed_ride_id do
      Repo.transaction(fn ->
        ride = fetch_completed_ride_for_update!(ride_id)
        ensure_rater_participated!(ride, rated_by_user_id)
        action = Actions.fetch_pending_action_for_update!(ride.id, rated_by_user_id, now)
        _ = Actions.mark_skipped!(action, now)

        _ =
          Events.record_event(ride.id, "ride_rating_skipped", now,
            actor_user_id: rated_by_user_id,
            payload: %{"rating_action_id" => action.id}
          )
          |> unwrap_or_rollback()

        %{ride_id: ride.id, rating_action_status: "skipped", driver_id: ride.driver_id}
      end)
      |> unwrap_transaction_result()
      |> maybe_broadcast_rating_skipped(rated_by_user_id)
    else
      _ -> {:error, :ride_not_found}
    end
  end

  defp fetch_completed_ride_for_update!(ride_id) do
    Repo.one(
      from r in Ride,
        where: r.id == ^ride_id and r.status == "completed",
        lock: "FOR UPDATE"
    ) || Repo.rollback(:ride_not_rateable)
  end

  defp ensure_rater_participated!(ride, rated_by_user_id) do
    if ride.rider_id == rated_by_user_id or ride.driver_id == rated_by_user_id do
      :ok
    else
      Repo.rollback(:ride_not_accessible)
    end
  end

  defp parse_score!(attrs) do
    score =
      attrs
      |> PaymentUtils.get_value(:score)
      |> case do
        value when is_integer(value) -> value
        value when is_binary(value) -> Integer.parse(String.trim(value)) |> elem_or_nil()
        _ -> nil
      end

    if score in 1..5, do: score, else: Repo.rollback(:invalid_rating_score)
  end

  defp parse_reason_tags(attrs) do
    attrs
    |> PaymentUtils.get_value(:reason_tags)
    |> normalize_reason_tags()
  end

  defp normalize_reason_tags(nil), do: []

  defp normalize_reason_tags(tags) when is_list(tags) do
    tags
    |> Enum.map(&PaymentUtils.normalize_text/1)
    |> Enum.map(fn
      nil -> nil
      value -> String.downcase(value)
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_reason_tags(_tags), do: []

  defp validate_reason_tags!(score, reason_tags) do
    if score < 5 and reason_tags == [] do
      Repo.rollback(:missing_rating_reasons)
    end
  end

  defp parse_comment(attrs) do
    attrs
    |> PaymentUtils.get_value(:comment)
    |> PaymentUtils.normalize_text()
  end

  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: value

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp parse_positive_integer(_value), do: nil

  defp elem_or_nil({value, ""}), do: value
  defp elem_or_nil(_), do: nil

  defp unwrap_transaction_result({:ok, payload}), do: {:ok, payload}
  defp unwrap_transaction_result({:error, reason}), do: {:error, reason}
  defp unwrap_or_rollback({:ok, value}), do: value
  defp unwrap_or_rollback({:error, changeset}), do: Repo.rollback(changeset)

  defp maybe_broadcast_rating_submitted(
         {:ok, %{ride_id: ride_id, driver_id: driver_id, rating: rating} = payload}
       ) do
    _ =
      EnforcementSignals.maybe_emit_low_rating_signal(
        rating.rated_user_id,
        payload.rated_user_stats,
        DateTime.utc_now() |> DateTime.truncate(:microsecond)
      )

    _ =
      AbuseSignals.maybe_emit_abuse_signals(
        rating,
        DateTime.utc_now() |> DateTime.truncate(:microsecond)
      )

    Realtime.broadcast_rating_submitted(ride_id, driver_id, rating)
    {:ok, Map.drop(payload, [:ride_id, :driver_id])}
  end

  defp maybe_broadcast_rating_submitted(other), do: other

  defp maybe_broadcast_rating_skipped(
         {:ok, %{ride_id: ride_id, driver_id: driver_id} = payload},
         rated_by_user_id
       ) do
    Realtime.broadcast_rating_skipped(ride_id, driver_id, rated_by_user_id)
    {:ok, Map.delete(payload, :driver_id)}
  end

  defp maybe_broadcast_rating_skipped(other, _rated_by_user_id), do: other
end
