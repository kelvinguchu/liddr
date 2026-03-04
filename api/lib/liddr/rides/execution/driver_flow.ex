defmodule Liddr.Rides.Execution.DriverFlow do
  alias Liddr.Rides.Events
  alias Liddr.Rides.Execution.Geofence
  alias Liddr.Repo
  alias Liddr.Rides.Execution.Shared
  alias Liddr.Rides.Realtime

  def mark_driver_arriving(driver_user_id, ride_id) do
    transition_driver_ride(driver_user_id, ride_id, :driver_arriving)
  end

  def mark_driver_arrived(driver_user_id, ride_id) do
    transition_driver_ride(driver_user_id, ride_id, :arrived)
  end

  def start_ride(driver_user_id, ride_id) do
    transition_driver_ride(driver_user_id, ride_id, :started)
  end

  defp transition_driver_ride(driver_user_id, ride_id, transition) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    result =
      Repo.transaction(fn ->
        ride = Shared.fetch_ride_for_update!(ride_id)
        Shared.ensure_driver_owns_ride!(ride, driver_user_id)
        driver = Shared.fetch_driver_for_update!(driver_user_id)
        Shared.ensure_driver_locked_to_ride!(driver, ride.id)
        apply_driver_transition!(ride, driver, transition, now, driver_user_id)
      end)
      |> Shared.unwrap_transaction_result()

    case result do
      {:ok, %{ride: ride, event: nil}} ->
        {:ok, ride}

      {:ok, %{ride: ride, event: :driver_arriving}} ->
        Realtime.broadcast_driver_arriving(ride)
        {:ok, ride}

      {:ok, %{ride: ride, event: :driver_arrived}} ->
        Realtime.broadcast_driver_arrived(ride)
        {:ok, ride}

      {:ok, %{ride: ride, event: :trip_started}} ->
        Realtime.broadcast_trip_started(ride)
        {:ok, ride}

      error ->
        error
    end
  end

  defp apply_driver_transition!(ride, driver, :driver_arriving, now, driver_user_id) do
    cond do
      ride.status == "driver_arriving" ->
        %{ride: ride, event: nil}

      ride.status == "accepted" ->
        updated_ride =
          Shared.update_ride!(ride, %{
            "status" => "driver_arriving",
            "driver_arriving_at" => ride.driver_arriving_at || now
          })

        _ = Shared.update_driver_dispatch!(driver, "heading_to_pickup", now)
        _ = record_transition_event(updated_ride.id, "driver_arriving", now, driver_user_id)
        %{ride: updated_ride, event: :driver_arriving}

      true ->
        Repo.rollback(:ride_not_arrivable)
    end
  end

  defp apply_driver_transition!(ride, driver, :arrived, now, driver_user_id) do
    cond do
      ride.status == "arrived" ->
        %{ride: ride, event: nil}

      ride.status in ["accepted", "driver_arriving"] ->
        geofence = Geofence.ensure_arrival!(ride, driver.user_id, now)

        updated_ride =
          Shared.update_ride!(ride, %{
            "status" => "arrived",
            "driver_arriving_at" => ride.driver_arriving_at || now,
            "arrived_at" => ride.arrived_at || now,
            "arrival_distance_m" => geofence.distance_m
          })

        _ = Shared.update_driver_dispatch!(driver, "at_pickup", now)

        _ =
          record_transition_event(
            updated_ride.id,
            "driver_arrived",
            now,
            driver_user_id,
            geofence.payload
          )

        %{ride: updated_ride, event: :driver_arrived}

      true ->
        Repo.rollback(:ride_not_arrivable)
    end
  end

  defp apply_driver_transition!(ride, driver, :started, now, driver_user_id) do
    cond do
      ride.status == "in_progress" ->
        %{ride: ride, event: nil}

      ride.status == "arrived" ->
        updated_ride =
          Shared.update_ride!(ride, %{
            "status" => "in_progress",
            "started_at" => ride.started_at || now
          })

        _ = Shared.update_driver_dispatch!(driver, "on_trip", now)
        _ = record_transition_event(updated_ride.id, "trip_started", now, driver_user_id)
        %{ride: updated_ride, event: :trip_started}

      true ->
        Repo.rollback(:ride_not_startable)
    end
  end

  defp record_transition_event(ride_id, event_type, occurred_at, actor_user_id, payload \\ %{}) do
    Events.record_event(ride_id, event_type, occurred_at,
      actor_user_id: actor_user_id,
      payload: payload
    )
    |> Shared.unwrap_or_rollback()
  end
end
