defmodule Liddr.Rides.Requests do
  require Logger

  alias Liddr.Repo
  alias Liddr.Rides.Dispatcher
  alias Liddr.Rides.Integrity.Booking
  alias Liddr.Rides.ProductType
  alias Liddr.Rides.Realtime
  alias Liddr.Rides.Requests.Creation
  alias Liddr.Rides.Requests.Lookup
  alias Liddr.Rides.Requests.Metadata, as: RequestMetadata
  alias Liddr.Rides.Requests.Params, as: RequestParams
  alias Liddr.Rides.SharedEligibility

  @default_offer_limit 3
  @max_offer_limit 10
  @default_offer_ttl_seconds 15
  @max_offer_ttl_seconds 120

  def request_ride(rider_user_id, attrs \\ %{}, opts \\ []) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    offer_limit = RequestParams.resolve_offer_limit(attrs, @default_offer_limit, @max_offer_limit)

    offer_ttl_seconds =
      RequestParams.resolve_offer_ttl_seconds(
        attrs,
        @default_offer_ttl_seconds,
        @max_offer_ttl_seconds
      )

    metadata_overrides = RequestParams.resolve_metadata_overrides(opts)

    case Repo.transaction(fn ->
           rider = Booking.fetch_rider_for_request!(rider_user_id, now)
           requested_payment_mode = Booking.ensure_request_allowed!(rider, attrs, now)
           category = Lookup.fetch_vehicle_category!(attrs)
           product_type = resolve_product_type!(attrs)
           ensure_shared_supported!(product_type, category)
           quote = Lookup.fetch_valid_quote!(attrs, rider_user_id, category.id, product_type, now)
           pickup_point = Lookup.fetch_pickup_point(quote, attrs)
           dropoff = Lookup.fetch_dropoff_coordinates(quote, attrs)
           dropoff_lat = dropoff.lat
           dropoff_lng = dropoff.lng

           shared_match_metadata =
             Creation.resolve_shared_match_metadata(
               product_type,
               rider_user_id,
               category.id,
               pickup_point,
               %{lat: dropoff_lat, lng: dropoff_lng},
               now
             )

           metadata =
             RequestMetadata.build(
               quote,
               requested_payment_mode,
               metadata_overrides,
               shared_match_metadata
             )

           request_result =
             Creation.build_request_result!(
               rider_user_id,
               attrs,
               category,
               product_type,
               quote,
               pickup_point,
               %{lat: dropoff_lat, lng: dropoff_lng},
               metadata,
               shared_match_metadata,
               now,
               offer_limit,
               offer_ttl_seconds
             )

           Map.merge(request_result, %{
             rider_booking_mode: rider.ride_booking_mode,
             rider_booking_mode_until: rider.ride_booking_mode_until
           })
         end) do
      {:ok, payload} ->
        Enum.each(payload.offers, &Realtime.broadcast_offer_created(payload.ride, &1))

        if dispatch_async_enabled?() do
          ensure_dispatch_worker(payload.ride.id, offer_limit, offer_ttl_seconds)
        end

        {:ok, payload}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_product_type!(attrs) do
    case ProductType.resolve(attrs) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp ensure_shared_supported!(product_type, category) do
    case SharedEligibility.ensure_supported_for_category(product_type, category) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp ensure_dispatch_worker(ride_id, offer_limit, offer_ttl_seconds) do
    case Dispatcher.ensure_started(ride_id,
           offer_limit: offer_limit,
           offer_ttl_seconds: offer_ttl_seconds
         ) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[rides.dispatch] failed to start worker ride_id=#{ride_id} reason=#{inspect(reason)}"
        )
    end
  end

  defp dispatch_async_enabled?,
    do: Application.get_env(:liddr, :rides_dispatch_async, true)
end
