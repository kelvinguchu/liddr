defmodule Liddr.Rides.Requests.Creation do
  @moduledoc false

  alias Liddr.Repo
  alias Liddr.Rides.CandidateSelection
  alias Liddr.Rides.DriverOfferLock
  alias Liddr.Rides.Events
  alias Liddr.Rides.Ride
  alias Liddr.Rides.RideOffer
  alias Liddr.Rides.SharedMatcher
  alias Liddr.Rides.SharedRides.Joiner
  alias Liddr.Rides.SharedRides.Setup, as: SharedSetup
  alias Liddr.Subscriptions.PaymentUtils

  def resolve_shared_match_metadata(
        "shared",
        rider_user_id,
        category_id,
        pickup,
        dropoff,
        now
      ) do
    SharedMatcher.match_for_request(rider_user_id, category_id, pickup, dropoff, now)
  end

  def resolve_shared_match_metadata(
        _product_type,
        _rider_user_id,
        _category_id,
        _pickup,
        _dropoff,
        _now
      ),
      do: nil

  def build_request_result!(
        rider_user_id,
        attrs,
        category,
        product_type,
        quote,
        pickup_point,
        dropoff,
        metadata,
        shared_match_metadata,
        now,
        offer_limit,
        offer_ttl_seconds
      ) do
    case maybe_join_existing_group!(
           rider_user_id,
           category.id,
           product_type,
           pickup_point,
           dropoff,
           quote,
           shared_match_metadata,
           now
         ) do
      :no_join ->
        create_new_ride_request!(
          rider_user_id,
          attrs,
          category,
          product_type,
          quote,
          pickup_point,
          dropoff,
          metadata,
          now,
          offer_limit,
          offer_ttl_seconds
        )

      %{ride: ride, group: group, member: member} ->
        %{
          ride: ride,
          offers: [],
          shared_join: %{
            "joined" => true,
            "group_id" => group.id,
            "member_id" => member.id,
            "ride_id" => ride.id
          }
        }
    end
  end

  defp create_new_ride_request!(
         rider_user_id,
         attrs,
         category,
         product_type,
         quote,
         pickup_point,
         dropoff,
         metadata,
         now,
         offer_limit,
         offer_ttl_seconds
       ) do
    ride =
      %Ride{}
      |> Ride.create_changeset(%{
        "rider_id" => rider_user_id,
        "quote_id" => quote && quote.id,
        "vehicle_category_id" => category.id,
        "status" => "requested",
        "product_type" => product_type,
        "pickup_lat" => pickup_point.lat,
        "pickup_lng" => pickup_point.lng,
        "dropoff_lat" => dropoff.lat,
        "dropoff_lng" => dropoff.lng,
        "requested_at" => now,
        "notes" => PaymentUtils.get_value(attrs, :notes),
        "metadata" => metadata
      })
      |> Repo.insert()
      |> unwrap_or_rollback()

    _ = maybe_setup_shared_ride!(ride, rider_user_id, now)

    eligible_driver_ids =
      CandidateSelection.list_eligible_driver_ids(category, pickup_point, offer_limit)

    offers = create_offers!(ride.id, eligible_driver_ids, now, offer_ttl_seconds)

    updated_ride =
      if offers == [] do
        ride
      else
        ride
        |> Ride.create_changeset(%{"status" => "offering"})
        |> Repo.update()
        |> unwrap_or_rollback()
      end

    _ =
      Events.record_event(updated_ride.id, "ride_requested", now,
        actor_user_id: rider_user_id,
        payload: %{
          "vehicle_category_id" => category.id,
          "offers_count" => length(offers)
        }
      )
      |> unwrap_or_rollback()

    _ =
      if offers == [] do
        Events.record_event(updated_ride.id, "ride_no_drivers_found", now,
          payload: %{"vehicle_category_id" => category.id}
        )
      else
        Events.record_event(updated_ride.id, "ride_offers_dispatched", now,
          payload: %{"offers_count" => length(offers)}
        )
      end
      |> unwrap_or_rollback()

    %{ride: updated_ride, offers: offers}
  end

  defp maybe_join_existing_group!(
         rider_user_id,
         category_id,
         "shared",
         pickup_point,
         dropoff_point,
         quote,
         shared_match_metadata,
         now
       ) do
    Joiner.try_join_existing_group!(
      rider_user_id,
      category_id,
      pickup_point,
      dropoff_point,
      quote,
      shared_match_metadata,
      now
    )
  end

  defp maybe_join_existing_group!(
         _rider_user_id,
         _category_id,
         _product_type,
         _pickup_point,
         _dropoff_point,
         _quote,
         _shared_match_metadata,
         _now
       ),
       do: :no_join

  defp create_offers!(ride_id, driver_ids, now, offer_ttl_seconds) do
    expires_at = DateTime.add(now, offer_ttl_seconds, :second)

    lock_result =
      DriverOfferLock.acquire_many(driver_ids, ride_id, offer_ttl_seconds,
        source: "request_initial_offers"
      )

    selected_driver_ids = lock_result.selected_driver_ids
    locked_driver_ids = lock_result.locked_driver_ids

    if selected_driver_ids == [] do
      []
    else
      rows =
        Enum.map(selected_driver_ids, fn driver_id ->
          %{
            ride_id: ride_id,
            driver_id: driver_id,
            status: "offered",
            offered_at: now,
            expires_at: expires_at,
            inserted_at: now,
            updated_at: now
          }
        end)

      {_, returning_rows} =
        Repo.insert_all(RideOffer, rows,
          on_conflict: :nothing,
          conflict_target: [:ride_id, :driver_id],
          returning: [:id, :ride_id, :driver_id, :status, :offered_at, :expires_at, :inserted_at]
        )

      offers =
        returning_rows
        |> normalize_rows()
        |> Enum.map(fn
          %RideOffer{} = offer -> offer
          row when is_map(row) -> struct(RideOffer, row)
        end)

      inserted_driver_ids = offers |> Enum.map(& &1.driver_id) |> MapSet.new()

      locked_driver_ids
      |> Enum.reject(&MapSet.member?(inserted_driver_ids, &1))
      |> Enum.map(&{&1, ride_id})
      |> DriverOfferLock.release_many(source: "request_insert_conflict")

      offers
    end
  end

  defp maybe_setup_shared_ride!(%Ride{product_type: "shared"} = ride, rider_user_id, now),
    do: SharedSetup.ensure_group_for_ride!(ride, rider_user_id, now)

  defp maybe_setup_shared_ride!(_ride, _rider_user_id, _now), do: :ok

  defp unwrap_or_rollback({:ok, value}), do: value
  defp unwrap_or_rollback({:error, changeset}), do: Repo.rollback(changeset)

  defp normalize_rows(nil), do: []
  defp normalize_rows(rows) when is_list(rows), do: rows
  defp normalize_rows(row), do: [row]
end
