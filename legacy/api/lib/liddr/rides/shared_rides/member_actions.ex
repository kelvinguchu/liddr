defmodule Liddr.Rides.SharedRides.MemberActions do
  @moduledoc false

  import Ecto.Query

  require Logger

  alias Liddr.Repo
  alias Liddr.Rides.Events
  alias Liddr.Rides.Execution.Cancellation
  alias Liddr.Rides.SharedRideMember
  alias Liddr.Rides.SharedRides.StopPlanner
  alias Liddr.Rides.Timeline
  alias Liddr.Rides.SharedRides.Context

  @terminal_statuses ~w(cancelled no_show dropped_off)

  def rider_cancel_member(rider_user_id, ride_id, member_id, attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    with {:ok, ride} <- Timeline.get_ride_for_user(rider_user_id, ride_id),
         :ok <- Context.ensure_shared_ride(ride),
         {:ok, member} <- fetch_member(ride.id, member_id),
         :ok <- ensure_member_owned_by_rider(member, rider_user_id),
         :ok <- ensure_primary_member(member, ride),
         {:ok, updated_ride} <- Cancellation.rider_cancel_ride(rider_user_id, ride.id, attrs) do
      _ = mark_member_cancelled(member, updated_ride, now)
      {:ok, Context.for_ride!(updated_ride.id, updated_ride)}
    end
  end

  def driver_mark_member_no_show(driver_user_id, ride_id, member_id, attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    with {:ok, ride} <- Timeline.get_ride_for_user(driver_user_id, ride_id),
         :ok <- Context.ensure_shared_ride(ride),
         {:ok, member} <- fetch_member(ride.id, member_id),
         :ok <- ensure_primary_member(member, ride),
         {:ok, updated_ride} <- Cancellation.mark_rider_no_show(driver_user_id, ride.id, attrs) do
      _ = mark_member_no_show(member, updated_ride, now)
      {:ok, Context.for_ride!(updated_ride.id, updated_ride)}
    end
  end

  defp fetch_member(ride_id, member_id) do
    parsed_member_id = parse_positive_integer(member_id)

    if is_nil(parsed_member_id) do
      {:error, :shared_member_not_found}
    else
      member =
        Repo.one(
          from m in SharedRideMember,
            where: m.id == ^parsed_member_id and m.ride_id == ^ride_id
        )

      if is_nil(member), do: {:error, :shared_member_not_found}, else: {:ok, member}
    end
  end

  defp ensure_member_owned_by_rider(%SharedRideMember{rider_user_id: rider_id}, rider_id), do: :ok

  defp ensure_member_owned_by_rider(_member, _rider_user_id),
    do: {:error, :shared_member_forbidden}

  defp ensure_primary_member(%SharedRideMember{rider_user_id: rider_id}, %{rider_id: rider_id}),
    do: :ok

  defp ensure_primary_member(_member, _ride), do: {:error, :shared_member_action_not_supported}

  defp mark_member_cancelled(%SharedRideMember{} = member, ride, now) do
    if member.status in @terminal_statuses do
      :ok
    else
      reason =
        ride.metadata
        |> Map.get("cancel_reason_code")
        |> to_string_or_nil()

      update_member(member, %{
        "status" => "cancelled",
        "cancelled_at" => now,
        "cancellation_reason_code" => reason || ride.cancellation_reason_code,
        "cancelled_by_user_id" => ride.cancelled_by_user_id
      })
      |> maybe_record_member_event(ride.id, "shared_member_cancelled", now)
    end
  end

  defp mark_member_no_show(%SharedRideMember{} = member, ride, now) do
    if member.status in @terminal_statuses do
      :ok
    else
      update_member(member, %{
        "status" => "no_show",
        "no_show_marked_at" => now,
        "cancelled_by_user_id" => ride.cancelled_by_user_id,
        "cancellation_reason_code" => ride.cancellation_reason_code
      })
      |> maybe_record_member_event(ride.id, "shared_member_no_show", now)
    end
  end

  defp update_member(member, attrs) do
    member
    |> SharedRideMember.create_changeset(attrs)
    |> Repo.update()
  end

  defp maybe_record_member_event({:ok, member}, ride_id, event_type, now) do
    _ =
      Events.record_event(ride_id, event_type, now,
        actor_user_id: member.cancelled_by_user_id,
        payload: %{"shared_member_id" => member.id, "status" => member.status}
      )

    _ = StopPlanner.replan_for_ride!(ride_id, now)

    :ok
  end

  defp maybe_record_member_event({:error, changeset}, _ride_id, _event_type, _now) do
    Logger.warning("[shared_rides] member update failed #{inspect(changeset.errors)}")
    :ok
  end

  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: value

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp parse_positive_integer(_value), do: nil

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value) when is_binary(value), do: value
  defp to_string_or_nil(value), do: to_string(value)
end
