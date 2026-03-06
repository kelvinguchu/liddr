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
  alias Liddr.Rides.RequestTiming
  alias Liddr.Rides.SharedEligibility
  alias Liddr.Rides.WomenOnly

  @default_offer_limit 3
  @max_offer_limit 10
  @default_offer_ttl_seconds 15
  @max_offer_ttl_seconds 120

  def request_ride(rider_user_id, attrs \\ %{}, opts \\ []) do
    started_at = System.monotonic_time()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    dispatch_async? = dispatch_async_enabled?()

    {offer_limit, timings} =
      RequestTiming.measure(:resolve_offer_limit, %{}, fn ->
        RequestParams.resolve_offer_limit(attrs, @default_offer_limit, @max_offer_limit)
      end)

    {offer_ttl_seconds, timings} =
      RequestTiming.measure(:resolve_offer_ttl_seconds, timings, fn ->
        RequestParams.resolve_offer_ttl_seconds(
          attrs,
          @default_offer_ttl_seconds,
          @max_offer_ttl_seconds
        )
      end)

    {metadata_overrides, timings} =
      RequestTiming.measure(:resolve_metadata_overrides, timings, fn ->
        RequestParams.resolve_metadata_overrides(opts)
      end)

    {transaction_result, timings} =
      RequestTiming.measure(:transaction, timings, fn ->
        Repo.transaction(fn ->
          {rider, tx_timings} =
            RequestTiming.measure(:fetch_rider, %{}, fn ->
              Booking.fetch_rider_for_request!(rider_user_id, now)
            end)

          {requested_payment_mode, tx_timings} =
            RequestTiming.measure(:ensure_request_allowed, tx_timings, fn ->
              Booking.ensure_request_allowed!(rider, attrs, now)
            end)

          {category, tx_timings} =
            RequestTiming.measure(:fetch_vehicle_category, tx_timings, fn ->
              Lookup.fetch_vehicle_category!(attrs)
            end)

          {_, tx_timings} =
            RequestTiming.measure(:ensure_women_only_eligible, tx_timings, fn ->
              WomenOnly.ensure_rider_eligible(rider, category) |> unwrap_or_rollback()
            end)

          {product_type, tx_timings} =
            RequestTiming.measure(:resolve_product_type, tx_timings, fn ->
              resolve_product_type!(attrs)
            end)

          {_, tx_timings} =
            RequestTiming.measure(:ensure_shared_supported, tx_timings, fn ->
              ensure_shared_supported!(product_type, category)
            end)

          {quote, tx_timings} =
            RequestTiming.measure(:fetch_valid_quote, tx_timings, fn ->
              Lookup.fetch_valid_quote!(attrs, rider_user_id, category.id, product_type, now)
            end)

          {pickup_point, tx_timings} =
            RequestTiming.measure(:fetch_pickup_point, tx_timings, fn ->
              Lookup.fetch_pickup_point(quote, attrs)
            end)

          {dropoff, tx_timings} =
            RequestTiming.measure(:fetch_dropoff_coordinates, tx_timings, fn ->
              Lookup.fetch_dropoff_coordinates(quote, attrs)
            end)

          dropoff_coords = %{lat: dropoff.lat, lng: dropoff.lng}

          {shared_match_metadata, tx_timings} =
            RequestTiming.measure(:resolve_shared_match_metadata, tx_timings, fn ->
              Creation.resolve_shared_match_metadata(
                product_type,
                rider_user_id,
                category.id,
                pickup_point,
                dropoff_coords,
                now
              )
            end)

          {metadata, tx_timings} =
            RequestTiming.measure(:build_metadata, tx_timings, fn ->
              RequestMetadata.build(
                quote,
                requested_payment_mode,
                metadata_overrides,
                shared_match_metadata
              )
            end)

          {request_result, tx_timings} =
            RequestTiming.measure(:build_request_result, tx_timings, fn ->
              Creation.build_request_result!(
                rider,
                rider_user_id,
                attrs,
                category,
                product_type,
                quote,
                pickup_point,
                dropoff_coords,
                metadata,
                shared_match_metadata,
                now,
                %{
                  inline?: not dispatch_async?,
                  offer_limit: offer_limit,
                  offer_ttl_seconds: offer_ttl_seconds
                }
              )
            end)

          payload =
            Map.merge(request_result, %{
              rider_booking_mode: rider.ride_booking_mode,
              rider_booking_mode_until: rider.ride_booking_mode_until
            })

          {payload, tx_timings}
        end)
      end)

    case transaction_result do
      {:ok, {payload, tx_timings}} ->
        timings =
          Map.delete(timings, :transaction)
          |> Map.merge(tx_timings)
          |> Map.put(:transaction, Map.fetch!(timings, :transaction))

        {_, timings} =
          RequestTiming.measure(:broadcast_offers, timings, fn ->
            Enum.each(payload.offers, &Realtime.broadcast_offer_created(payload.ride, &1))
          end)

        if dispatch_async? do
          {_, timings} =
            RequestTiming.measure(:schedule_dispatch_worker, timings, fn ->
              schedule_dispatch_worker(payload.ride.id, offer_limit, offer_ttl_seconds)
            end)

          RequestTiming.maybe_log_slow(
            System.monotonic_time() - started_at,
            timings,
            request_timing_metadata(dispatch_async?, offer_limit, offer_ttl_seconds, payload)
          )
        else
          RequestTiming.maybe_log_slow(
            System.monotonic_time() - started_at,
            timings,
            request_timing_metadata(dispatch_async?, offer_limit, offer_ttl_seconds, payload)
          )
        end

        {:ok, payload}

      {:error, reason} ->
        RequestTiming.maybe_log_slow(
          System.monotonic_time() - started_at,
          timings,
          %{
            dispatch_async: dispatch_async?,
            offer_limit: offer_limit,
            offer_ttl_seconds: offer_ttl_seconds
          }
        )

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

  defp schedule_dispatch_worker(ride_id, offer_limit, offer_ttl_seconds) do
    Task.start(fn ->
      ensure_dispatch_worker(ride_id, offer_limit, offer_ttl_seconds)
    end)

    :ok
  end

  defp dispatch_async_enabled?,
    do: Application.get_env(:liddr, :rides_dispatch_async, true)

  defp request_timing_metadata(dispatch_async?, offer_limit, offer_ttl_seconds, payload) do
    %{
      dispatch_async: dispatch_async?,
      offer_limit: offer_limit,
      offer_ttl_seconds: offer_ttl_seconds,
      product_type: payload.ride.product_type,
      offers_count: length(payload.offers)
    }
  end

  defp unwrap_or_rollback(:ok), do: :ok
  defp unwrap_or_rollback({:error, reason}), do: Repo.rollback(reason)
end
