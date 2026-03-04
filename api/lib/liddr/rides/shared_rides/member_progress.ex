defmodule Liddr.Rides.SharedRides.MemberProgress do
  @moduledoc false

  import Ecto.Query

  alias Liddr.Repo
  alias Liddr.Rides.Geo
  alias Liddr.Rides.Events
  alias Liddr.Rides.SharedRideMember
  alias Liddr.Rides.SharedRideStop
  alias Liddr.Rides.SharedRides.Context
  alias Liddr.Rides.SharedRides.StopPlanner
  alias Liddr.Rides.Timeline

  @pickup_arrivable_statuses ~w(requested assigned pickup_pending)
  @pickup_ready_statuses ~w(requested assigned pickup_pending)
  @dropoff_ready_statuses ~w(picked_up dropoff_pending)

  def driver_arrive_member_pickup(driver_user_id, ride_id, member_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.transaction(fn ->
      with {:ok, ride} <- Timeline.get_ride_for_user(driver_user_id, ride_id),
           :ok <- Context.ensure_shared_ride(ride),
           :ok <- ensure_driver_assigned(ride, driver_user_id),
           {:ok, member} <- fetch_member_for_update(ride.id, member_id),
           :ok <-
             ensure_status(member, @pickup_arrivable_statuses, :shared_member_not_pickup_ready) do
        updated_member =
          update_member!(member, %{
            "status" => "pickup_pending"
          })

        record_member_event!(
          ride.id,
          "shared_member_pickup_arrived",
          driver_user_id,
          updated_member,
          now
        )

        {:ok, Context.for_ride!(ride.id, ride)}
      end
    end)
    |> unwrap_transaction_result()
  end

  def driver_mark_member_picked_up(driver_user_id, ride_id, member_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.transaction(fn ->
      with {:ok, ride} <- Timeline.get_ride_for_user(driver_user_id, ride_id),
           :ok <- Context.ensure_shared_ride(ride),
           :ok <- ensure_driver_assigned(ride, driver_user_id),
           {:ok, member} <- fetch_member_for_update(ride.id, member_id),
           :ok <- ensure_status(member, @pickup_ready_statuses, :shared_member_not_pickup_ready) do
        updated_member =
          update_member!(member, %{
            "status" => "picked_up",
            "picked_up_at" => now
          })

        mark_stop_completed!(ride.id, member.id, "pickup", now)
        refresh_pending_eta!(ride, updated_member, :pickup, now)

        record_member_event!(
          ride.id,
          "shared_member_picked_up",
          driver_user_id,
          updated_member,
          now
        )

        {:ok, Context.for_ride!(ride.id, ride)}
      end
    end)
    |> unwrap_transaction_result()
  end

  def driver_mark_member_dropped_off(driver_user_id, ride_id, member_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.transaction(fn ->
      with {:ok, ride} <- Timeline.get_ride_for_user(driver_user_id, ride_id),
           :ok <- Context.ensure_shared_ride(ride),
           :ok <- ensure_driver_assigned(ride, driver_user_id),
           {:ok, member} <- fetch_member_for_update(ride.id, member_id),
           :ok <- ensure_status(member, @dropoff_ready_statuses, :shared_member_not_dropoff_ready) do
        updated_member =
          update_member!(member, %{
            "status" => "dropped_off",
            "dropped_off_at" => now
          })

        mark_stop_completed!(ride.id, member.id, "dropoff", now)
        refresh_pending_eta!(ride, updated_member, :dropoff, now)

        record_member_event!(
          ride.id,
          "shared_member_dropped_off",
          driver_user_id,
          updated_member,
          now
        )

        {:ok, Context.for_ride!(ride.id, ride)}
      end
    end)
    |> unwrap_transaction_result()
  end

  defp ensure_driver_assigned(%{driver_id: driver_id}, driver_id), do: :ok
  defp ensure_driver_assigned(_ride, _driver_user_id), do: {:error, :ride_not_assigned_to_driver}

  defp fetch_member_for_update(ride_id, member_id) do
    parsed_member_id = parse_positive_integer(member_id)

    if is_nil(parsed_member_id) do
      {:error, :shared_member_not_found}
    else
      member =
        Repo.one(
          from m in SharedRideMember,
            where: m.id == ^parsed_member_id and m.ride_id == ^ride_id,
            lock: "FOR UPDATE",
            limit: 1
        )

      if is_nil(member), do: {:error, :shared_member_not_found}, else: {:ok, member}
    end
  end

  defp ensure_status(member, allowed, error_code) do
    if member.status in allowed, do: :ok, else: {:error, error_code}
  end

  defp update_member!(member, attrs) do
    member
    |> SharedRideMember.create_changeset(attrs)
    |> Repo.update!()
  end

  defp mark_stop_completed!(ride_id, member_id, stop_type, now) do
    _ =
      Repo.update_all(
        from(s in SharedRideStop,
          where:
            s.ride_id == ^ride_id and s.member_id == ^member_id and s.stop_type == ^stop_type and
              s.status == "pending"
        ),
        set: [status: "completed", completed_at: now, updated_at: now]
      )

    :ok
  end

  defp record_member_event!(ride_id, event_type, actor_user_id, member, now) do
    _ =
      Events.record_event(ride_id, event_type, now,
        actor_user_id: actor_user_id,
        payload: %{"shared_member_id" => member.id, "status" => member.status}
      )
      |> unwrap_or_rollback()

    :ok
  end

  defp refresh_pending_eta!(ride, member, stop_type, now) do
    start_point = member_point_or_fallback(member, ride, stop_type)
    _ = StopPlanner.refresh_pending_eta_for_ride!(ride.id, start_point, now)
    :ok
  end

  defp member_point_or_fallback(member, ride, :pickup) do
    metadata = normalize_metadata(member.metadata)

    lat = Map.get(metadata, "pickup_lat", ride.pickup_lat)
    lng = Map.get(metadata, "pickup_lng", ride.pickup_lng)
    {Geo.to_float(lat), Geo.to_float(lng)}
  end

  defp member_point_or_fallback(member, ride, :dropoff) do
    metadata = normalize_metadata(member.metadata)

    lat = Map.get(metadata, "dropoff_lat", ride.dropoff_lat)
    lng = Map.get(metadata, "dropoff_lng", ride.dropoff_lng)
    {Geo.to_float(lat), Geo.to_float(lng)}
  end

  defp normalize_metadata(%{} = metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}

  defp unwrap_transaction_result({:ok, {:ok, payload}}), do: {:ok, payload}
  defp unwrap_transaction_result({:ok, {:error, reason}}), do: {:error, reason}
  defp unwrap_transaction_result({:error, reason}), do: {:error, reason}

  defp unwrap_or_rollback({:ok, value}), do: value
  defp unwrap_or_rollback({:error, changeset}), do: Repo.rollback(changeset)

  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: value

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp parse_positive_integer(_value), do: nil
end
