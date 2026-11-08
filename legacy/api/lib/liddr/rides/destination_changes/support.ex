defmodule Liddr.Rides.DestinationChanges.Support do
  import Ecto.Query

  alias Decimal, as: D
  alias Liddr.Location.DriverLocation
  alias Liddr.Repo
  alias Liddr.Rides.DestinationChanges.Policy
  alias Liddr.Rides.Execution.Shared
  alias Liddr.Rides.Ride
  alias Liddr.Rides.RideDestinationChange
  alias Liddr.Rides.RideQuote
  alias Liddr.Rides.RoutePricing
  alias Liddr.Rides.VehicleCategory
  alias Liddr.Subscriptions.PaymentUtils

  @max_changes_per_ride 2

  def ensure_destination_change_allowed!(%Ride{status: status, product_type: product_type}) do
    cond do
      status != "in_progress" -> Repo.rollback(:ride_destination_change_not_allowed)
      product_type == "shared" -> Repo.rollback(:ride_destination_change_not_allowed_for_shared)
      true -> :ok
    end
  end

  def ensure_destination_change_window!(%Ride{started_at: nil}, _now) do
    Repo.rollback(:ride_destination_change_not_allowed)
  end

  def ensure_destination_change_window!(%Ride{started_at: started_at}, now) do
    elapsed_seconds = max(DateTime.diff(now, started_at, :second), 0)

    if elapsed_seconds > Policy.max_elapsed_seconds() do
      Repo.rollback(:destination_change_window_elapsed)
    else
      :ok
    end
  end

  def ensure_destination_change_cooldown!(ride_id, now) do
    cooldown_seconds = Policy.cooldown_seconds()

    if cooldown_seconds <= 0 do
      :ok
    else
      latest_requested_at =
        Repo.one(
          from dc in RideDestinationChange,
            where: dc.ride_id == ^ride_id,
            order_by: [desc: dc.requested_at],
            limit: 1,
            select: dc.requested_at
        )

      within_cooldown? =
        case latest_requested_at do
          %DateTime{} = requested_at ->
            DateTime.diff(now, requested_at, :second) < cooldown_seconds

          _ ->
            false
        end

      if within_cooldown?,
        do: Repo.rollback(:destination_change_cooldown_active),
        else: :ok
    end
  end

  def ensure_destination_change_quota!(ride_id) do
    count =
      Repo.aggregate(
        from(dc in RideDestinationChange, where: dc.ride_id == ^ride_id),
        :count,
        :id
      )

    if count >= @max_changes_per_ride,
      do: Repo.rollback(:destination_change_limit_reached),
      else: :ok
  end

  def ensure_no_open_change!(ride_id) do
    open_exists? =
      Repo.exists?(
        from dc in RideDestinationChange,
          where: dc.ride_id == ^ride_id and dc.status == "requested"
      )

    if open_exists?, do: Repo.rollback(:destination_change_already_pending), else: :ok
  end

  def fetch_open_change_for_update!(ride_id, change_id, driver_user_id) do
    parsed_id =
      Shared.parse_positive_integer(change_id) || Repo.rollback(:destination_change_not_found)

    Repo.one(
      from dc in RideDestinationChange,
        where:
          dc.id == ^parsed_id and dc.ride_id == ^ride_id and dc.driver_id == ^driver_user_id and
            dc.status == "requested",
        lock: "FOR UPDATE"
    ) || Repo.rollback(:destination_change_not_found)
  end

  def ensure_change_request_fresh!(change, now) do
    age_seconds = max(DateTime.diff(now, change.requested_at, :second), 0)

    if age_seconds > Policy.request_ttl_seconds() do
      Repo.rollback(:destination_change_request_stale)
    else
      :ok
    end
  end

  def resolve_reason_code!(attrs, allowed_codes) do
    reason =
      attrs
      |> PaymentUtils.get_value(:reason_code)
      |> PaymentUtils.normalize_text()

    if reason in allowed_codes,
      do: reason,
      else: Repo.rollback(:invalid_destination_change_reason)
  end

  def resolve_optional_reason_code(attrs, allowed_codes) do
    reason =
      attrs
      |> PaymentUtils.get_value(:reason_code)
      |> PaymentUtils.normalize_text()

    cond do
      is_nil(reason) -> {:ok, "driver_declined"}
      reason in allowed_codes -> {:ok, reason}
      true -> {:error, :invalid_destination_change_reason}
    end
  end

  def resolve_notes(attrs) do
    attrs
    |> PaymentUtils.get_value(:notes)
    |> PaymentUtils.normalize_text()
  end

  def fetch_new_dropoff!(attrs) do
    with {:ok, lat} <-
           parse_coordinate(PaymentUtils.get_value(attrs, :new_dropoff_lat), -90.0, 90.0),
         {:ok, lng} <-
           parse_coordinate(PaymentUtils.get_value(attrs, :new_dropoff_lng), -180.0, 180.0) do
      %{lat: lat, lng: lng}
    else
      _ -> Repo.rollback(:invalid_destination_coordinates)
    end
  end

  def ensure_destination_changed!(ride, destination) do
    current_lat = ride.dropoff_lat |> to_float()
    current_lng = ride.dropoff_lng |> to_float()

    if abs(current_lat - destination.lat) < 0.00001 and
         abs(current_lng - destination.lng) < 0.00001 do
      Repo.rollback(:destination_change_same_as_current)
    else
      :ok
    end
  end

  def fetch_vehicle_category!(category_id) do
    Repo.get(VehicleCategory, category_id) || Repo.rollback(:vehicle_category_not_found)
  end

  def current_origin_point!(
        %Ride{
          driver_id: driver_user_id,
          pickup_lat: pickup_lat,
          pickup_lng: pickup_lng
        },
        now
      ) do
    location =
      Repo.one(
        from dl in DriverLocation,
          where: dl.driver_id == ^driver_user_id,
          order_by: [desc: dl.captured_at],
          limit: 1
      )

    if location do
      ensure_origin_location_fresh!(location, now)
      %{lat: to_float(location.lat), lng: to_float(location.lng)}
    else
      %{lat: to_float(pickup_lat), lng: to_float(pickup_lng)}
    end
  end

  def current_planned_fare(%Ride{} = ride) do
    quote =
      case ride.quote_id do
        nil -> nil
        quote_id -> Repo.get(RideQuote, quote_id)
      end

    metadata_fare =
      ride.metadata
      |> Shared.normalize_metadata()
      |> Map.get("quoted_final_fare_kes")
      |> parse_decimal()

    metadata_fare || (quote && quote.final_fare_kes) || ride.final_fare_kes || D.new("0.00")
  end

  def estimate_route_pricing!(category, origin, destination, now) do
    case RoutePricing.estimate(category, origin, destination, now) do
      {:ok, payload} -> payload
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  def to_decimal(value), do: D.from_float(value) |> D.round(7)

  defp parse_coordinate(value, min, max) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} when parsed >= min and parsed <= max -> {:ok, parsed}
      _ -> {:error, :invalid_coordinate}
    end
  end

  defp parse_coordinate(value, min, max) when is_integer(value),
    do: parse_coordinate(value * 1.0, min, max)

  defp parse_coordinate(value, min, max) when is_float(value) and value >= min and value <= max,
    do: {:ok, value}

  defp parse_coordinate(_value, _min, _max), do: {:error, :invalid_coordinate}

  defp to_float(%D{} = value), do: D.to_float(value)
  defp to_float(value) when is_float(value), do: value
  defp to_float(value) when is_integer(value), do: value * 1.0
  defp to_float(_value), do: 0.0

  defp parse_decimal(%D{} = value), do: value

  defp parse_decimal(value) when is_binary(value) do
    case D.parse(String.trim(value)) do
      {decimal, ""} -> decimal
      _ -> nil
    end
  end

  defp parse_decimal(_value), do: nil

  defp ensure_origin_location_fresh!(%DriverLocation{captured_at: nil}, _now) do
    Repo.rollback(:destination_change_origin_stale)
  end

  defp ensure_origin_location_fresh!(%DriverLocation{captured_at: captured_at}, now) do
    age_seconds = max(DateTime.diff(now, captured_at, :second), 0)

    if age_seconds > Policy.origin_location_freshness_seconds() do
      Repo.rollback(:destination_change_origin_stale)
    else
      :ok
    end
  end
end
