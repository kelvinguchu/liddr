defmodule Liddr.Rides.Integrity.Enforcement do
  @moduledoc false

  import Ecto.Query

  alias Liddr.Accounts.User
  alias Liddr.Moderation.Enforcements, as: ModerationEnforcements
  alias Liddr.Repo
  alias Liddr.Rides.Integrity.Policy
  alias Liddr.Rides.Ride

  def apply_after_cancellation!(%Ride{} = _ride, integrity, now) do
    if integrity["chargeable"] == true and is_integer(integrity["subject_user_id"]) do
      count =
        count_chargeable_events_7d(
          integrity["subject_user_id"],
          integrity["subject_role"],
          Policy.rolling_window_start(now)
        )

      action =
        case integrity["subject_role"] do
          "rider" -> maybe_apply_rider_prepay_only!(integrity["subject_user_id"], count, now)
          "driver" -> maybe_apply_driver_suspension!(integrity["subject_user_id"], count, now)
          _ -> nil
        end

      %{"chargeable_events_7d" => count, "action" => action}
    else
      %{"chargeable_events_7d" => nil, "action" => nil}
    end
  end

  def count_chargeable_events_7d(subject_user_id, subject_role, window_start) do
    subject_user_id_text = Integer.to_string(subject_user_id)

    Repo.aggregate(
      from(r in Ride,
        where: r.status == "cancelled" and r.cancelled_at >= ^window_start,
        where:
          fragment("?->'integrity'->>'chargeable' = 'true'", r.metadata) and
            fragment("?->'integrity'->>'subject_role' = ?", r.metadata, ^subject_role) and
            fragment("?->'integrity'->>'subject_user_id' = ?", r.metadata, ^subject_user_id_text)
      ),
      :count,
      :id
    )
  end

  defp maybe_apply_rider_prepay_only!(rider_user_id, chargeable_count, now) do
    threshold = Policy.rider_chargeable_threshold()
    escalation_threshold = Policy.rider_chargeable_escalation_threshold()

    cond do
      chargeable_count >= escalation_threshold ->
        apply_rider_mode!(
          rider_user_id,
          chargeable_count,
          now,
          Policy.rider_prepay_only_escalation_days()
        )

      chargeable_count >= threshold ->
        apply_rider_mode!(rider_user_id, chargeable_count, now, Policy.rider_prepay_only_days())

      true ->
        nil
    end
  end

  defp maybe_apply_driver_suspension!(driver_user_id, chargeable_count, now) do
    threshold = Policy.driver_chargeable_threshold()
    escalation_threshold = Policy.driver_chargeable_escalation_threshold()

    cond do
      chargeable_count >= escalation_threshold ->
        apply_driver_temporary_suspension!(
          driver_user_id,
          chargeable_count,
          now,
          Policy.driver_temp_suspension_escalation_days(),
          "driver_chargeable_events_escalated"
        )

      chargeable_count >= threshold ->
        apply_driver_temporary_suspension!(
          driver_user_id,
          chargeable_count,
          now,
          Policy.driver_temp_suspension_days(),
          "driver_chargeable_events_threshold_reached"
        )

      true ->
        nil
    end
  end

  defp apply_driver_temporary_suspension!(
         driver_user_id,
         chargeable_count,
         now,
         days,
         reason_code
       ) do
    ends_at = DateTime.add(now, days * 86_400, :second)

    enforcement =
      ModerationEnforcements.apply_enforcement_in_transaction!(%{
        "user_id" => driver_user_id,
        "scope" => "rides",
        "action" => "temporary_suspension",
        "status" => "active",
        "reason_code" => reason_code,
        "reason_text" =>
          "Automatic suspension after repeated chargeable ride cancellations/no-shows",
        "starts_at" => now,
        "ends_at" => ends_at,
        "metadata" => %{
          "source" => "ride_integrity",
          "chargeable_events_7d" => chargeable_count,
          "suspension_days" => days
        }
      })

    %{
      "type" => "driver_temporary_suspension",
      "days" => days,
      "chargeable_events_7d" => chargeable_count,
      "enforcement_id" => enforcement.id,
      "starts_at" => enforcement.starts_at,
      "ends_at" => enforcement.ends_at
    }
  end

  defp apply_rider_mode!(rider_user_id, chargeable_count, now, days) do
    user =
      Repo.one(from u in User, where: u.id == ^rider_user_id, lock: "FOR UPDATE") ||
        Repo.rollback(:user_not_found)

    requested_until = DateTime.add(now, days * 86_400, :second)
    mode_until = max_datetime(user.ride_booking_mode_until, requested_until)

    _updated_user =
      user
      |> User.ride_booking_mode_changeset(%{
        "ride_booking_mode" => "prepay_only",
        "ride_booking_mode_until" => mode_until
      })
      |> Repo.update()
      |> unwrap_or_rollback()

    %{
      "type" => "rider_prepay_only",
      "days" => days,
      "ride_booking_mode" => "prepay_only",
      "ride_booking_mode_until" => mode_until,
      "chargeable_events_7d" => chargeable_count
    }
  end

  defp max_datetime(nil, value), do: value
  defp max_datetime(value, nil), do: value

  defp max_datetime(left, right) do
    if DateTime.compare(left, right) == :lt, do: right, else: left
  end

  defp unwrap_or_rollback({:ok, value}), do: value
  defp unwrap_or_rollback({:error, changeset}), do: Repo.rollback(changeset)
end
