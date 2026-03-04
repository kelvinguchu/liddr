defmodule Liddr.Rides.DestinationChanges do
  alias Decimal, as: D
  alias Liddr.Repo
  alias Liddr.Rides.Events
  alias Liddr.Rides.Execution.Shared
  alias Liddr.Rides.Realtime
  alias Liddr.Rides.RideDestinationChange
  alias Liddr.Rides.DestinationChanges.Support

  @request_reason_codes ~w(
    rider_changed_plan
    wrong_dropoff_selected
    traffic_or_safety
    intermediate_stop
    other
  )
  @reject_reason_codes ~w(driver_declined unsafe_request route_unserviceable other)

  def request_change(rider_user_id, ride_id, attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    result =
      Repo.transaction(fn ->
        ride = Shared.fetch_ride_for_update!(ride_id)
        Shared.ensure_rider_owns_ride!(ride, rider_user_id)
        Support.ensure_destination_change_allowed!(ride)
        Support.ensure_destination_change_quota!(ride.id)
        Support.ensure_no_open_change!(ride.id)

        reason_code = Support.resolve_reason_code!(attrs, @request_reason_codes)
        notes = Support.resolve_notes(attrs)
        destination = Support.fetch_new_dropoff!(attrs)
        Support.ensure_destination_changed!(ride, destination)
        category = Support.fetch_vehicle_category!(ride.vehicle_category_id)
        origin = Support.current_origin_point(ride)
        old_fare = Support.current_planned_fare(ride)
        estimate = Support.estimate_route_pricing!(category, origin, destination, now)

        new_fare = estimate.pricing.final_fare_kes
        fare_delta = D.sub(new_fare, old_fare)

        change =
          %RideDestinationChange{}
          |> RideDestinationChange.create_changeset(%{
            "ride_id" => ride.id,
            "requested_by_user_id" => rider_user_id,
            "driver_id" => ride.driver_id,
            "old_dropoff_lat" => ride.dropoff_lat,
            "old_dropoff_lng" => ride.dropoff_lng,
            "new_dropoff_lat" => Support.to_decimal(destination.lat),
            "new_dropoff_lng" => Support.to_decimal(destination.lng),
            "old_fare_kes" => old_fare,
            "new_fare_kes" => new_fare,
            "fare_delta_kes" => fare_delta,
            "status" => "requested",
            "reason_code" => reason_code,
            "notes" => notes,
            "requested_at" => now,
            "pricing_payload" => Support.pricing_payload(estimate)
          })
          |> Repo.insert()
          |> Shared.unwrap_or_rollback()

        _ =
          Events.record_event(ride.id, "destination_change_requested", now,
            actor_user_id: rider_user_id,
            payload: Support.destination_change_event_payload(change)
          )
          |> Shared.unwrap_or_rollback()

        %{ride: ride, destination_change: change}
      end)
      |> Shared.unwrap_transaction_result()

    case result do
      {:ok, %{ride: ride, destination_change: change} = payload} ->
        Realtime.broadcast_destination_change_requested(ride, change)
        {:ok, payload}

      error ->
        error
    end
  end

  def accept_change(driver_user_id, ride_id, change_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    result =
      Repo.transaction(fn ->
        ride = Shared.fetch_ride_for_update!(ride_id)
        Shared.ensure_driver_owns_ride!(ride, driver_user_id)
        Support.ensure_destination_change_allowed!(ride)
        change = Support.fetch_open_change_for_update!(ride.id, change_id, driver_user_id)

        accepted_change =
          change
          |> RideDestinationChange.create_changeset(%{
            "status" => "accepted",
            "responded_at" => now
          })
          |> Repo.update()
          |> Shared.unwrap_or_rollback()

        updated_ride =
          Shared.update_ride!(ride, %{
            "dropoff_lat" => accepted_change.new_dropoff_lat,
            "dropoff_lng" => accepted_change.new_dropoff_lng,
            "metadata" => Support.destination_change_metadata(ride.metadata, accepted_change)
          })

        _ =
          Events.record_event(updated_ride.id, "destination_change_accepted", now,
            actor_user_id: driver_user_id,
            payload: Support.destination_change_event_payload(accepted_change)
          )
          |> Shared.unwrap_or_rollback()

        %{ride: updated_ride, destination_change: accepted_change}
      end)
      |> Shared.unwrap_transaction_result()

    case result do
      {:ok, %{ride: ride, destination_change: change} = payload} ->
        Realtime.broadcast_destination_change_accepted(ride, change)
        {:ok, payload}

      error ->
        error
    end
  end

  def reject_change(driver_user_id, ride_id, change_id, attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    with {:ok, reason_code} <- Support.resolve_optional_reason_code(attrs, @reject_reason_codes) do
      result =
        Repo.transaction(fn ->
          ride = Shared.fetch_ride_for_update!(ride_id)
          Shared.ensure_driver_owns_ride!(ride, driver_user_id)
          Support.ensure_destination_change_allowed!(ride)
          change = Support.fetch_open_change_for_update!(ride.id, change_id, driver_user_id)

          rejected_change =
            change
            |> RideDestinationChange.create_changeset(%{
              "status" => "rejected",
              "reason_code" => reason_code,
              "notes" => Support.resolve_notes(attrs) || change.notes,
              "responded_at" => now
            })
            |> Repo.update()
            |> Shared.unwrap_or_rollback()

          _ =
            Events.record_event(ride.id, "destination_change_rejected", now,
              actor_user_id: driver_user_id,
              payload: Support.destination_change_event_payload(rejected_change)
            )
            |> Shared.unwrap_or_rollback()

          %{ride: ride, destination_change: rejected_change}
        end)
        |> Shared.unwrap_transaction_result()

      case result do
        {:ok, %{ride: ride, destination_change: change} = payload} ->
          Realtime.broadcast_destination_change_rejected(ride, change)
          {:ok, payload}

        error ->
          error
      end
    end
  end
end
