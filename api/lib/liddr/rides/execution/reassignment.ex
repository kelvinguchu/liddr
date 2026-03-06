defmodule Liddr.Rides.Execution.Reassignment do
  @moduledoc false

  import Ecto.Query

  alias Liddr.Repo
  alias Liddr.Location
  alias Liddr.Rides.DriverOfferLock
  alias Liddr.Rides.Dispatcher
  alias Liddr.Rides.Events
  alias Liddr.Rides.Execution.PickupHealth
  alias Liddr.Rides.Execution.ReassignmentSupport
  alias Liddr.Rides.Execution.Shared
  alias Liddr.Rides.Realtime
  alias Liddr.Rides.RideOffer

  @reassignable_statuses ~w(accepted driver_arriving)

  def pickup_health(rider_user_id, ride_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    with {:ok, ride} <- fetch_rider_ride(rider_user_id, ride_id) do
      {:ok, %{ride: ride, health: PickupHealth.evaluate(ride, now)}}
    end
  end

  def request_reassign(rider_user_id, ride_id, attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    result =
      Repo.transaction(fn ->
        ride = Shared.fetch_ride_for_update!(ride_id)
        Shared.ensure_rider_owns_ride!(ride, rider_user_id)
        ensure_reassignable!(ride)

        health = PickupHealth.evaluate(ride, now)

        if health["recommend_reassign"] != true do
          Repo.rollback(:reassign_not_recommended)
        end

        previous_driver_id = ride.driver_id || Repo.rollback(:ride_not_reassignable)
        driver = Shared.fetch_driver_for_update!(previous_driver_id)
        active_offer = fetch_active_offer_for_driver(ride.id, previous_driver_id)
        withdrawn_offer = maybe_withdraw_offer(active_offer, now)

        metadata =
          ride.metadata
          |> Shared.normalize_metadata()
          |> ReassignmentSupport.enrich_reassign_metadata(previous_driver_id, health, attrs, now)

        updated_ride =
          Shared.update_ride!(ride, %{
            "status" => "offering",
            "driver_id" => nil,
            "accepted_at" => nil,
            "driver_arriving_at" => nil,
            "arrived_at" => nil,
            "arrival_distance_m" => nil,
            "metadata" => metadata
          })

        status_signal = ReassignmentSupport.status_signal_from_health(health)

        _ =
          ReassignmentSupport.record_status_signal_event(
            updated_ride.id,
            rider_user_id,
            previous_driver_id,
            status_signal,
            health,
            now
          )

        reassigning_payload = %{
          "previous_driver_id" => previous_driver_id,
          "recommendation_reason_code" => health["recommendation_reason_code"],
          "signals" => health["signals"],
          "flags" => health["flags"],
          "trigger_reason" => ReassignmentSupport.get_reassign_trigger_reason(attrs)
        }

        _ =
          Events.record_event(updated_ride.id, "reassigning_driver", now,
            actor_user_id: rider_user_id,
            payload: reassigning_payload
          )
          |> Shared.unwrap_or_rollback()

        _ =
          if driver.current_ride_id == ride.id do
            Shared.release_driver_after_cancellation!(driver, now)
          else
            driver
          end

        _ =
          Events.record_event(updated_ride.id, "ride_reassign_requested", now,
            actor_user_id: rider_user_id,
            payload: %{
              "previous_driver_id" => previous_driver_id,
              "recommendation_reason_code" => health["recommendation_reason_code"],
              "signals" => health["signals"],
              "flags" => health["flags"]
            }
          )
          |> Shared.unwrap_or_rollback()

        %{
          ride: updated_ride,
          withdrawn_offer: withdrawn_offer,
          health: health,
          previous_driver_id: previous_driver_id,
          status_signal: status_signal,
          reassigning_payload: reassigning_payload
        }
      end)
      |> Shared.unwrap_transaction_result()

    case result do
      {:ok, payload} ->
        _ = Location.sync_driver_supply(payload.previous_driver_id)
        DriverOfferLock.release_many([payload.withdrawn_offer], source: "rider_reassign")
        ReassignmentSupport.broadcast_offer_withdrawn(payload.ride.id, payload.withdrawn_offer)
        ReassignmentSupport.broadcast_status_signal(payload)

        Realtime.broadcast_reassigning_driver(
          payload.ride,
          payload.reassigning_payload,
          payload.previous_driver_id
        )

        Realtime.broadcast_ride_reassigned(
          payload.ride,
          payload.health,
          payload.previous_driver_id
        )

        _ = Dispatcher.ensure_started(payload.ride.id)
        :ok = Dispatcher.dispatch_now(payload.ride.id)
        {:ok, payload.ride}

      error ->
        error
    end
  end

  defp fetch_rider_ride(rider_user_id, ride_id) do
    parsed_ride_id = Shared.parse_positive_integer(ride_id)

    cond do
      is_nil(parsed_ride_id) ->
        {:error, :ride_not_found}

      true ->
        case Repo.one(
               from r in Liddr.Rides.Ride,
                 where: r.id == ^parsed_ride_id and r.rider_id == ^rider_user_id,
                 limit: 1
             ) do
          nil -> {:error, :ride_not_assigned_to_rider}
          ride -> {:ok, ride}
        end
    end
  end

  defp ensure_reassignable!(ride) do
    if ride.status in @reassignable_statuses and is_integer(ride.driver_id),
      do: :ok,
      else: Repo.rollback(:ride_not_reassignable)
  end

  defp fetch_active_offer_for_driver(ride_id, driver_id) do
    Repo.one(
      from o in RideOffer,
        where:
          o.ride_id == ^ride_id and o.driver_id == ^driver_id and
            o.status in ["accepted", "offered"],
        order_by: [desc: o.inserted_at],
        lock: "FOR UPDATE",
        limit: 1
    )
  end

  defp maybe_withdraw_offer(nil, _now), do: nil

  defp maybe_withdraw_offer(offer, now) do
    offer
    |> RideOffer.create_changeset(%{"status" => "withdrawn", "responded_at" => now})
    |> Repo.update()
    |> Shared.unwrap_or_rollback()
  end
end
