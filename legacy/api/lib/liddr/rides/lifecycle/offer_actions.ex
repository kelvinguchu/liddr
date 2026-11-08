defmodule Liddr.Rides.Lifecycle.OfferActions do
  import Ecto.Query

  alias Liddr.Location
  alias Liddr.Location.DriverHotState
  alias Liddr.Repo
  alias Liddr.Rides.Dispatcher
  alias Liddr.Rides.DriverOfferLock
  alias Liddr.Rides.Events
  alias Liddr.Rides.Integrity.AcceptanceTelemetry
  alias Liddr.Rides.Lifecycle.OfferActionsSupport
  alias Liddr.Rides.Realtime
  alias Liddr.Rides.Ride
  alias Liddr.Rides.RideOffer

  def accept_offer(driver_user_id, offer_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    result =
      Repo.transaction(fn ->
        offer = OfferActionsSupport.fetch_offer_for_update!(offer_id)
        OfferActionsSupport.ensure_offer_belongs_to_driver!(offer, driver_user_id)
        OfferActionsSupport.ensure_offer_open!(offer, now)

        driver = OfferActionsSupport.ensure_driver_eligible_for_accept!(driver_user_id, now)
        ride = OfferActionsSupport.fetch_ride_for_update!(offer.ride_id)
        OfferActionsSupport.ensure_ride_assignable!(ride)

        competing_ride_offers = list_competing_ride_offers(ride.id, offer.id)
        competing_driver_offers = list_competing_driver_offers(driver_user_id, ride.id)

        withdraw_competing_ride_offers(ride.id, offer.id, now)
        withdraw_competing_driver_offers(driver_user_id, ride.id, now)

        accepted_offer =
          offer
          |> RideOffer.create_changeset(%{"status" => "accepted", "responded_at" => now})
          |> Repo.update()
          |> OfferActionsSupport.unwrap_or_rollback()

        ride_metadata =
          ride.metadata
          |> OfferActionsSupport.normalize_ride_metadata()
          |> maybe_put_driver_snapshot(accepted_offer)
          |> Map.merge(AcceptanceTelemetry.metadata_for_accept(ride, driver_user_id))

        updated_ride =
          ride
          |> Ride.create_changeset(%{
            "status" => "accepted",
            "driver_id" => driver_user_id,
            "accepted_at" => now,
            "metadata" => ride_metadata
          })
          |> Repo.update()
          |> OfferActionsSupport.unwrap_or_rollback()

        _updated_driver =
          driver
          |> Liddr.Accounts.Driver.create_changeset(%{
            "current_ride_id" => ride.id,
            "dispatch_status" => "heading_to_pickup",
            "is_available" => false,
            "last_seen_at" => now
          })
          |> Repo.update()
          |> OfferActionsSupport.unwrap_or_rollback()
          |> tap(&DriverHotState.put/1)

        _ =
          Events.record_event(ride.id, "ride_accepted", now,
            actor_user_id: driver_user_id,
            payload: %{"offer_id" => accepted_offer.id}
          )
          |> OfferActionsSupport.unwrap_or_rollback()

        new_driver_found_payload =
          OfferActionsSupport.build_new_driver_found_payload(
            ride.metadata,
            driver_user_id,
            accepted_offer.id
          )

        _ =
          OfferActionsSupport.maybe_record_new_driver_found_event(
            ride.id,
            driver_user_id,
            new_driver_found_payload,
            now
          )
          |> OfferActionsSupport.unwrap_or_rollback()

        %{
          ride: updated_ride,
          offer: accepted_offer,
          competing_ride_offers: competing_ride_offers,
          competing_driver_offers: competing_driver_offers,
          new_driver_found_payload: new_driver_found_payload
        }
      end)
      |> OfferActionsSupport.unwrap_transaction_result()
      |> OfferActionsSupport.normalize_accept_error()

    case result do
      {:ok,
       %{
         ride: ride,
         offer: accepted_offer,
         competing_ride_offers: competing_ride_offers,
         competing_driver_offers: competing_driver_offers,
         new_driver_found_payload: new_driver_found_payload
       } = payload} ->
        _ = Location.remove_driver_from_supply(driver_user_id)

        DriverOfferLock.release_many(
          [accepted_offer | competing_ride_offers ++ competing_driver_offers],
          source: "offer_accept"
        )

        Realtime.broadcast_ride_assigned(ride, accepted_offer)
        OfferActionsSupport.maybe_broadcast_new_driver_found(ride, new_driver_found_payload)

        Enum.each(
          competing_ride_offers,
          &Realtime.broadcast_offer_withdrawn(ride.id, &1, "ride_assigned")
        )

        Enum.each(
          competing_driver_offers,
          &Realtime.broadcast_offer_withdrawn(&1.ride_id, &1, "driver_busy")
        )

        Dispatcher.stop(ride.id)
        {:ok, Map.take(payload, [:ride, :offer])}

      _ ->
        result
    end
  end

  def reject_offer(driver_user_id, offer_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    result =
      Repo.transaction(fn ->
        offer = OfferActionsSupport.fetch_offer_for_update!(offer_id)
        OfferActionsSupport.ensure_offer_belongs_to_driver!(offer, driver_user_id)
        OfferActionsSupport.ensure_offer_open!(offer, now)
        ride = OfferActionsSupport.fetch_ride_for_update!(offer.ride_id)

        rejected_offer =
          offer
          |> RideOffer.create_changeset(%{"status" => "rejected", "responded_at" => now})
          |> Repo.update()
          |> OfferActionsSupport.unwrap_or_rollback()

        _ =
          Events.record_event(ride.id, "offer_rejected", now,
            actor_user_id: driver_user_id,
            payload: %{"offer_id" => rejected_offer.id}
          )
          |> OfferActionsSupport.unwrap_or_rollback()

        %{ride: ride, offer: rejected_offer}
      end)
      |> OfferActionsSupport.unwrap_transaction_result()

    case result do
      {:ok, %{ride: ride, offer: rejected_offer} = payload} ->
        DriverOfferLock.release_many([rejected_offer], source: "offer_reject")
        Realtime.broadcast_offer_withdrawn(ride.id, rejected_offer, "driver_rejected")
        _ = Dispatcher.ensure_started(ride.id)
        :ok = Dispatcher.dispatch_now(ride.id)
        {:ok, payload}

      _ ->
        result
    end
  end

  defp list_competing_ride_offers(ride_id, accepted_offer_id) do
    Repo.all(
      from o in RideOffer,
        where: o.ride_id == ^ride_id and o.id != ^accepted_offer_id and o.status == "offered"
    )
  end

  defp list_competing_driver_offers(driver_user_id, accepted_ride_id) do
    Repo.all(
      from o in RideOffer,
        where:
          o.driver_id == ^driver_user_id and o.ride_id != ^accepted_ride_id and
            o.status == "offered"
    )
  end

  defp withdraw_competing_ride_offers(ride_id, accepted_offer_id, now) do
    _ =
      Repo.update_all(
        from(o in RideOffer,
          where: o.ride_id == ^ride_id and o.id != ^accepted_offer_id and o.status == "offered"
        ),
        set: [status: "withdrawn", responded_at: now, updated_at: now]
      )

    :ok
  end

  defp withdraw_competing_driver_offers(driver_user_id, accepted_ride_id, now) do
    _ =
      Repo.update_all(
        from(o in RideOffer,
          where:
            o.driver_id == ^driver_user_id and o.ride_id != ^accepted_ride_id and
              o.status == "offered"
        ),
        set: [status: "withdrawn", responded_at: now, updated_at: now]
      )

    :ok
  end

  defp maybe_put_driver_snapshot(metadata, %RideOffer{
         metadata: %{"driver_rating_snapshot" => snapshot}
       })
       when is_map(snapshot) do
    Map.put(metadata, "driver_rating_snapshot", snapshot)
  end

  defp maybe_put_driver_snapshot(metadata, _offer), do: metadata
end
