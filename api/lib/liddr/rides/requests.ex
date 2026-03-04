defmodule Liddr.Rides.Requests do
  import Ecto.Query

  require Logger

  alias Liddr.Repo
  alias Liddr.Rides.CandidateSelection
  alias Liddr.Rides.Dispatcher
  alias Liddr.Rides.Events
  alias Liddr.Rides.Integrity.Booking
  alias Liddr.Rides.Realtime
  alias Liddr.Rides.Ride
  alias Liddr.Rides.RideOffer
  alias Liddr.Rides.RideQuote
  alias Liddr.Rides.VehicleCategory
  alias Liddr.Subscriptions.PaymentUtils

  @default_offer_limit 3
  @max_offer_limit 10
  @default_offer_ttl_seconds 15
  @max_offer_ttl_seconds 120
  @product_types ~w(solo shared)

  def request_ride(rider_user_id, attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    offer_limit = resolve_offer_limit(attrs)
    offer_ttl_seconds = resolve_offer_ttl_seconds(attrs)

    case Repo.transaction(fn ->
           rider = Booking.fetch_rider_for_request!(rider_user_id, now)
           requested_payment_mode = Booking.ensure_request_allowed!(rider, attrs, now)
           category = fetch_vehicle_category!(attrs)
           quote = fetch_valid_quote!(attrs, rider_user_id, category.id, now)
           pickup_point = fetch_pickup_point(quote, attrs)

           ride =
             %Ride{}
             |> Ride.create_changeset(%{
               "rider_id" => rider_user_id,
               "quote_id" => quote && quote.id,
               "vehicle_category_id" => category.id,
               "status" => "requested",
               "product_type" => resolve_product_type!(attrs),
               "pickup_lat" => pickup_point.lat,
               "pickup_lng" => pickup_point.lng,
               "dropoff_lat" => fetch_coordinate_value(quote, attrs, :dropoff_lat),
               "dropoff_lng" => fetch_coordinate_value(quote, attrs, :dropoff_lng),
               "requested_at" => now,
               "notes" => PaymentUtils.get_value(attrs, :notes),
               "metadata" => quote_metadata(quote, requested_payment_mode)
             })
             |> Repo.insert()
             |> unwrap_or_rollback()

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

           %{
             ride: updated_ride,
             offers: offers,
             rider_booking_mode: rider.ride_booking_mode,
             rider_booking_mode_until: rider.ride_booking_mode_until
           }
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

  defp create_offers!(ride_id, driver_ids, now, offer_ttl_seconds) do
    expires_at = DateTime.add(now, offer_ttl_seconds, :second)

    Enum.map(driver_ids, fn driver_id ->
      %RideOffer{}
      |> RideOffer.create_changeset(%{
        "ride_id" => ride_id,
        "driver_id" => driver_id,
        "status" => "offered",
        "offered_at" => now,
        "expires_at" => expires_at
      })
      |> Repo.insert()
      |> unwrap_or_rollback()
    end)
  end

  defp fetch_vehicle_category!(attrs) do
    category_id =
      attrs
      |> PaymentUtils.get_value(:vehicle_category_id)
      |> parse_positive_integer()

    if is_nil(category_id), do: Repo.rollback(:invalid_vehicle_category_id)

    Repo.one(
      from vc in VehicleCategory,
        where: vc.id == ^category_id and vc.is_active == true,
        limit: 1
    ) || Repo.rollback(:vehicle_category_not_found)
  end

  defp fetch_valid_quote!(attrs, rider_user_id, category_id, now) do
    quote_id = PaymentUtils.get_value(attrs, :quote_id)

    if is_nil(quote_id) do
      nil
    else
      parsed_quote_id = parse_positive_integer(quote_id) || Repo.rollback(:invalid_quote_id)

      quote =
        Repo.one(
          from q in RideQuote,
            where: q.id == ^parsed_quote_id and q.rider_id == ^rider_user_id,
            limit: 1
        ) || Repo.rollback(:ride_quote_not_found)

      if DateTime.compare(quote.expires_at, now) != :gt do
        Repo.rollback(:ride_quote_expired)
      end

      if quote.vehicle_category_id != category_id do
        Repo.rollback(:ride_quote_vehicle_category_mismatch)
      end

      quote
    end
  end

  defp fetch_coordinate_value(nil, attrs, key), do: PaymentUtils.get_value(attrs, key)
  defp fetch_coordinate_value(%RideQuote{} = quote, _attrs, :dropoff_lat), do: quote.dropoff_lat
  defp fetch_coordinate_value(%RideQuote{} = quote, _attrs, :dropoff_lng), do: quote.dropoff_lng

  defp fetch_pickup_point(nil, attrs) do
    %{
      lat: PaymentUtils.get_value(attrs, :pickup_lat) |> to_float_or_nil(),
      lng: PaymentUtils.get_value(attrs, :pickup_lng) |> to_float_or_nil()
    }
  end

  defp fetch_pickup_point(%RideQuote{} = quote, _attrs),
    do: %{lat: to_float_or_nil(quote.pickup_lat), lng: to_float_or_nil(quote.pickup_lng)}

  defp to_float_or_nil(%Decimal{} = value), do: Decimal.to_float(value)
  defp to_float_or_nil(value) when is_float(value), do: value
  defp to_float_or_nil(value) when is_integer(value), do: value * 1.0

  defp to_float_or_nil(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp to_float_or_nil(_value), do: nil

  defp quote_metadata(nil, nil), do: %{}

  defp quote_metadata(nil, requested_payment_mode) do
    if is_binary(requested_payment_mode),
      do: %{"requested_payment_mode" => requested_payment_mode},
      else: %{}
  end

  defp quote_metadata(%RideQuote{} = quote, requested_payment_mode) do
    base = %{
      "quote_id" => quote.id,
      "quote_expires_at" => quote.expires_at,
      "quoted_final_fare_kes" => quote.final_fare_kes,
      "quoted_distance_m" => quote.distance_m,
      "quoted_duration_s" => quote.duration_s
    }

    if is_binary(requested_payment_mode),
      do: Map.put(base, "requested_payment_mode", requested_payment_mode),
      else: base
  end

  defp resolve_offer_limit(attrs) do
    attrs
    |> PaymentUtils.get_value(:offer_limit)
    |> parse_positive_integer()
    |> clamp(@default_offer_limit, @max_offer_limit)
  end

  defp resolve_offer_ttl_seconds(attrs) do
    attrs
    |> PaymentUtils.get_value(:offer_ttl_seconds)
    |> parse_positive_integer()
    |> clamp(@default_offer_ttl_seconds, @max_offer_ttl_seconds)
  end

  defp clamp(nil, default, _max), do: default
  defp clamp(value, _default, max) when value > max, do: max
  defp clamp(value, _default, _max), do: value

  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: value

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp parse_positive_integer(_value), do: nil

  defp resolve_product_type!(attrs) do
    product_type =
      attrs
      |> PaymentUtils.get_value(:product_type)
      |> PaymentUtils.normalize_text()

    cond do
      is_nil(product_type) ->
        "solo"

      product_type in @product_types ->
        product_type

      true ->
        Repo.rollback(:invalid_product_type)
    end
  end

  defp unwrap_or_rollback({:ok, value}), do: value
  defp unwrap_or_rollback({:error, changeset}), do: Repo.rollback(changeset)

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
