defmodule Liddr.Rides.MarketMultiplier do
  @moduledoc false

  import Ecto.Query

  alias Decimal, as: D
  alias Liddr.Accounts.Driver
  alias Liddr.Accounts.User
  alias Liddr.Location.DriverLocation
  alias Liddr.Repo
  alias Liddr.Rides.CandidateSelection
  alias Liddr.Rides.Ride
  alias Liddr.Rides.VehicleCategory

  @blocked_user_statuses ~w(suspended banned deactivated)
  @location_freshness_seconds 30
  @request_window_seconds 180

  @category_max_market_multiplier %{
    "motorbike" => D.new("1.70"),
    "electric_motorbike" => D.new("1.70"),
    "send" => D.new("1.70"),
    "basic" => D.new("1.80"),
    "economy" => D.new("1.80"),
    "green" => D.new("1.80"),
    "women_only" => D.new("1.80"),
    "comfort" => D.new("2.00"),
    "xl" => D.new("2.00")
  }

  def build(%VehicleCategory{} = category, pickup, now \\ DateTime.utc_now()) do
    time_multiplier = time_multiplier(now)

    demand_snapshot =
      demand_snapshot(
        category,
        pickup,
        now |> DateTime.truncate(:microsecond)
      )

    demand_multiplier = demand_multiplier(demand_snapshot.ratio)

    market_multiplier =
      time_multiplier
      |> D.mult(demand_multiplier)
      |> max_decimal(D.new("1.00"))
      |> min_decimal(max_market_multiplier_for(category.slug))

    {:ok,
     %{
       time_multiplier: D.round(time_multiplier, 2),
       demand_multiplier: D.round(demand_multiplier, 2),
       market_multiplier: D.round(market_multiplier, 2),
       demand_ratio: D.round(D.from_float(demand_snapshot.ratio), 2),
       available_driver_count: demand_snapshot.available_driver_count,
       active_request_count: demand_snapshot.active_request_count
     }}
  end

  defp time_multiplier(now) do
    local_now = DateTime.add(now, 3 * 60 * 60, :second)
    minutes = local_now.hour * 60 + local_now.minute

    base =
      cond do
        minutes < 5 * 60 -> D.new("1.25")
        minutes < 6 * 60 + 30 -> D.new("1.05")
        minutes < 9 * 60 + 30 -> D.new("1.18")
        minutes < 16 * 60 + 30 -> D.new("1.00")
        minutes < 20 * 60 + 30 -> D.new("1.22")
        true -> D.new("1.08")
      end

    if weekend_late_night?(local_now) do
      base
      |> D.add(D.new("0.10"))
      |> min_decimal(D.new("1.35"))
    else
      base
    end
  end

  defp weekend_late_night?(local_now) do
    minutes = local_now.hour * 60 + local_now.minute
    day_of_week = local_now |> DateTime.to_date() |> Date.day_of_week()

    cond do
      day_of_week in [5, 6] and minutes >= 22 * 60 -> true
      day_of_week in [6, 7] and minutes < 4 * 60 -> true
      true -> false
    end
  end

  defp demand_snapshot(%VehicleCategory{} = category, pickup, now) do
    radius_km = CandidateSelection.search_radius_km(category)
    {min_lat, max_lat, min_lng, max_lng} = bbox(pickup, radius_km)
    freshness_cutoff = DateTime.add(now, -@location_freshness_seconds, :second)
    request_cutoff = DateTime.add(now, -@request_window_seconds, :second)

    available_driver_count =
      Repo.aggregate(
        from(d in Driver,
          join: u in User,
          on: u.id == d.user_id,
          join: dl in DriverLocation,
          on: dl.driver_id == d.user_id,
          where:
            d.vehicle_category_id == ^category.id and d.account_status == "active" and
              d.verification_status == "approved" and d.subscription_status == "active" and
              d.is_available == true and is_nil(d.current_ride_id) and d.dispatch_status == "idle" and
              dl.captured_at >= ^freshness_cutoff and dl.lat >= ^to_decimal(min_lat) and
              dl.lat <= ^to_decimal(max_lat) and dl.lng >= ^to_decimal(min_lng) and
              dl.lng <= ^to_decimal(max_lng) and
              (is_nil(u.account_status) or u.account_status not in ^@blocked_user_statuses),
          distinct: true
        ),
        :count,
        :user_id
      )

    active_request_count =
      Repo.aggregate(
        from(r in Ride,
          where:
            r.vehicle_category_id == ^category.id and r.status in ["requested", "offering"] and
              r.requested_at >= ^request_cutoff and r.pickup_lat >= ^to_decimal(min_lat) and
              r.pickup_lat <= ^to_decimal(max_lat) and r.pickup_lng >= ^to_decimal(min_lng) and
              r.pickup_lng <= ^to_decimal(max_lng)
        ),
        :count,
        :id
      )

    ratio =
      cond do
        available_driver_count > 0 ->
          active_request_count / available_driver_count

        active_request_count > 0 ->
          4.0

        true ->
          0.0
      end

    %{
      available_driver_count: available_driver_count,
      active_request_count: active_request_count,
      ratio: ratio
    }
  end

  defp demand_multiplier(ratio) when ratio <= 0.8, do: D.new("1.00")
  defp demand_multiplier(ratio) when ratio <= 1.2, do: D.new("1.05")
  defp demand_multiplier(ratio) when ratio <= 1.5, do: D.new("1.12")
  defp demand_multiplier(ratio) when ratio <= 2.0, do: D.new("1.25")
  defp demand_multiplier(ratio) when ratio <= 3.0, do: D.new("1.40")
  defp demand_multiplier(_ratio), do: D.new("1.55")

  defp max_market_multiplier_for(slug),
    do: Map.get(@category_max_market_multiplier, slug, D.new("1.80"))

  defp bbox(%{lat: lat, lng: lng}, radius_km) do
    lat_delta = radius_km / 111.0
    lng_delta = radius_km / (111.0 * max(:math.cos(lat * :math.pi() / 180.0), 0.1))
    {lat - lat_delta, lat + lat_delta, lng - lng_delta, lng + lng_delta}
  end

  defp max_decimal(left, right) do
    if D.compare(left, right) == :lt, do: right, else: left
  end

  defp min_decimal(left, right) do
    if D.compare(left, right) == :gt, do: right, else: left
  end

  defp to_decimal(value), do: D.from_float(value) |> D.round(7)
end
