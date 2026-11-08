defmodule Liddr.Rides.Requests.Creation do
  @moduledoc false

  alias Liddr.Repo
  alias Liddr.Ratings.Snapshot
  alias Liddr.Rides.CandidateSelection
  alias Liddr.Rides.Events
  alias Liddr.Rides.Ride
  alias Liddr.Rides.SharedMatcher
  alias Liddr.Rides.Requests.OfferCreation
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
        rider,
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
        dispatch_config
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
          rider,
          rider_user_id,
          attrs,
          category,
          product_type,
          quote,
          pickup_point,
          dropoff,
          metadata,
          now,
          dispatch_config
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
         rider,
         rider_user_id,
         attrs,
         category,
         product_type,
         quote,
         pickup_point,
         dropoff,
         metadata,
         now,
         dispatch_config
       ) do
    inline_dispatch? = dispatch_config.inline?

    ride =
      %Ride{}
      |> Ride.create_changeset(%{
        "rider_id" => rider_user_id,
        "quote_id" => quote && quote.id,
        "vehicle_category_id" => category.id,
        "status" => if(inline_dispatch?, do: "requested", else: "offering"),
        "product_type" => product_type,
        "pickup_lat" => pickup_point.lat,
        "pickup_lng" => pickup_point.lng,
        "dropoff_lat" => dropoff.lat,
        "dropoff_lng" => dropoff.lng,
        "requested_at" => now,
        "notes" => PaymentUtils.get_value(attrs, :notes),
        "metadata" =>
          Map.put(metadata, "rider_rating_snapshot", Snapshot.snapshot_for_user(rider, :rider))
      })
      |> Repo.insert()
      |> unwrap_or_rollback()

    _ = maybe_setup_shared_ride!(ride, rider_user_id, now)

    {updated_ride, offers} =
      maybe_dispatch_inline!(
        inline_dispatch?,
        ride,
        category,
        pickup_point,
        now,
        dispatch_config.offer_limit,
        dispatch_config.offer_ttl_seconds
      )

    _ =
      Events.record_event(updated_ride.id, "ride_requested", now,
        actor_user_id: rider_user_id,
        payload: %{
          "vehicle_category_id" => category.id,
          "offers_count" => length(offers)
        }
      )
      |> unwrap_or_rollback()

    maybe_record_inline_dispatch_event!(inline_dispatch?, updated_ride, category.id, offers, now)

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

  defp maybe_setup_shared_ride!(%Ride{product_type: "shared"} = ride, rider_user_id, now),
    do: SharedSetup.ensure_group_for_ride!(ride, rider_user_id, now)

  defp maybe_setup_shared_ride!(_ride, _rider_user_id, _now), do: :ok

  defp maybe_dispatch_inline!(false, ride, _category, _pickup_point, _now, _offer_limit, _ttl),
    do: {ride, []}

  defp maybe_dispatch_inline!(true, ride, category, pickup_point, now, offer_limit, ttl) do
    eligible_drivers =
      CandidateSelection.list_eligible_drivers(category, pickup_point, offer_limit,
        dispatch_eta_enabled: false
      )

    offers = OfferCreation.create_initial_offers!(ride.id, eligible_drivers, now, ttl)

    updated_ride =
      if offers == [] do
        ride
      else
        ride
        |> Ride.create_changeset(%{"status" => "offering"})
        |> Repo.update()
        |> unwrap_or_rollback()
      end

    {updated_ride, offers}
  end

  defp maybe_record_inline_dispatch_event!(false, _ride, _category_id, _offers, _now), do: :ok

  defp maybe_record_inline_dispatch_event!(true, ride, category_id, offers, now) do
    event =
      if offers == [] do
        Events.record_event(ride.id, "ride_no_drivers_found", now,
          payload: %{"vehicle_category_id" => category_id}
        )
      else
        Events.record_event(ride.id, "ride_offers_dispatched", now,
          payload: %{"offers_count" => length(offers)}
        )
      end

    event |> unwrap_or_rollback()
  end

  defp unwrap_or_rollback({:ok, value}), do: value
  defp unwrap_or_rollback({:error, changeset}), do: Repo.rollback(changeset)
end
