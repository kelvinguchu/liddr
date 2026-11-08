defmodule Liddr.Location do
  @moduledoc false

  import Ecto.Query
  require Logger

  alias Liddr.Accounts.Driver
  alias Liddr.Location.DriverHotState
  alias Liddr.Location.DriverLocationWriteGate
  alias Liddr.Location.DriverLocationRepoTelemetry
  alias Liddr.Location.DriverLocation
  alias Liddr.Location.S2
  alias Liddr.Location.SupplyIndex
  alias Liddr.Repo
  alias Liddr.Rides.SharedRides.LocationEtaRefresh
  alias Liddr.Subscriptions.PaymentUtils

  @driver_last_seen_update_interval_seconds 15
  @slow_location_update_threshold_ms 250

  def upsert_driver_location(driver_user_id, attrs \\ %{}) do
    started_at = System.monotonic_time()

    {result, repo_summary} =
      DriverLocationRepoTelemetry.track(fn ->
        do_upsert_driver_location(driver_user_id, attrs, started_at)
      end)

    DriverLocationRepoTelemetry.emit_summary(repo_summary)
    result
  end

  def sync_driver_supply(driver_user_id) when is_integer(driver_user_id) do
    driver =
      case DriverHotState.fetch(driver_user_id) do
        {:ok, snapshot} -> snapshot
        _ -> nil
      end

    location = Repo.get(DriverLocation, driver_user_id)

    cond do
      is_nil(driver) ->
        SupplyIndex.remove_driver(driver_user_id)

      is_nil(location) ->
        SupplyIndex.remove_driver(driver_user_id)

      eligible_for_supply?(driver) ->
        SupplyIndex.upsert_driver(
          driver.user_id,
          driver.vehicle_category_id,
          decimal_to_float(location.lat),
          decimal_to_float(location.lng),
          location.captured_at,
          location.s2_cell_token
        )

      true ->
        SupplyIndex.remove_driver(driver_user_id)
    end

    :ok
  end

  def sync_driver_supply(_driver_user_id), do: :ok

  def remove_driver_from_supply(driver_user_id) when is_integer(driver_user_id) do
    _ = SupplyIndex.remove_driver(driver_user_id)
    :ok
  end

  def remove_driver_from_supply(_driver_user_id), do: :ok

  defp do_upsert_driver_location(driver_user_id, attrs, started_at) do
    with {{:ok, %{user_id: _user_id} = driver}, timings} <-
           measure(:fetch_driver, %{}, fn -> DriverHotState.fetch(driver_user_id) end),
         {{:ok, lat}, timings} <-
           measure(:parse_lat, timings, fn ->
             parse_coordinate(PaymentUtils.get_value(attrs, :lat), -90.0, 90.0)
           end),
         {{:ok, lng}, timings} <-
           measure(:parse_lng, timings, fn ->
             parse_coordinate(PaymentUtils.get_value(attrs, :lng), -180.0, 180.0)
           end) do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      lat_decimal = Decimal.from_float(lat) |> Decimal.round(7)
      lng_decimal = Decimal.from_float(lng) |> Decimal.round(7)
      {cell_token, timings} = measure(:s2_token, timings, fn -> S2.token(lat, lng) end)

      {write_result, timings} =
        measure(:upsert_location, timings, fn ->
          persist_driver_location(
            driver_user_id,
            lat,
            lng,
            lat_decimal,
            lng_decimal,
            now,
            cell_token,
            attrs
          )
        end)

      case write_result do
        {:ok, _location} = result ->
          {updated_driver, timings} =
            measure(:update_last_seen, timings, fn -> update_driver_last_seen(driver, now) end)

          {_, timings} =
            measure(:sync_supply, timings, fn ->
              sync_driver_supply(updated_driver, lat, lng, now, cell_token)
            end)

          {_, timings} =
            measure(:shared_eta_refresh, timings, fn ->
              maybe_refresh_shared_eta(updated_driver, lat, lng, now)
            end)

          maybe_log_slow_location(started_at, timings, driver_user_id)
          result

        {:error, _changeset} = error ->
          maybe_log_slow_location(started_at, timings, driver_user_id)
          error
      end
    else
      {:error, :driver_profile_not_found} ->
        {:error, :driver_profile_not_found}

      _ ->
        {:error, :invalid_driver_location}
    end
  end

  defp sync_driver_supply(%{user_id: user_id} = driver, lat, lng, captured_at, cell_token) do
    if eligible_for_supply?(driver) do
      SupplyIndex.upsert_driver(
        user_id,
        driver.vehicle_category_id,
        lat,
        lng,
        captured_at,
        cell_token
      )
    else
      SupplyIndex.remove_driver(driver.user_id)
    end

    :ok
  end

  defp update_driver_last_seen(%{user_id: user_id, last_seen_at: last_seen_at} = driver, now) do
    if stale_last_seen?(last_seen_at, now) do
      from(d in Driver, where: d.user_id == ^user_id)
      |> Repo.update_all(set: [last_seen_at: now, updated_at: now])
    end

    latest_seen_at = max_last_seen(last_seen_at, now)
    :ok = DriverHotState.touch_last_seen(user_id, latest_seen_at)
    %{driver | user_id: user_id, last_seen_at: latest_seen_at}
  end

  defp stale_last_seen?(nil, _now), do: true

  defp stale_last_seen?(last_seen_at, now) do
    DateTime.diff(now, last_seen_at, :second) >= @driver_last_seen_update_interval_seconds
  end

  defp maybe_refresh_shared_eta(%{current_ride_id: ride_id, user_id: user_id}, lat, lng, now)
       when is_integer(ride_id) and ride_id > 0 do
    LocationEtaRefresh.maybe_refresh_for_driver(user_id, lat, lng, now)
  end

  defp maybe_refresh_shared_eta(_driver, _lat, _lng, _now), do: :ok

  defp maybe_log_slow_location(started_at, timings, driver_user_id) do
    repo_summary =
      DriverLocationRepoTelemetry.normalize(
        Process.get({DriverLocationRepoTelemetry, :summary}, %{})
      )

    total_ms = duration_ms(System.monotonic_time() - started_at)

    if total_ms >= @slow_location_update_threshold_ms do
      Logger.warning(
        "[location.update.timing] slow update total_ms=#{total_ms} timings_ms=#{inspect(normalize_timings(timings))} repo_ms=#{inspect(repo_summary)} metadata=#{inspect(%{driver_user_id: driver_user_id})}"
      )
    end
  end

  defp persist_driver_location(
         driver_user_id,
         lat,
         lng,
         lat_decimal,
         lng_decimal,
         now,
         cell_token,
         attrs
       ) do
    if DriverLocationWriteGate.should_persist?(driver_user_id, lat, lng, now) do
      result =
        upsert_driver_location_record(
          driver_user_id,
          lat_decimal,
          lng_decimal,
          now,
          cell_token,
          attrs
        )

      case result do
        {:ok, _location} ->
          :ok = DriverLocationWriteGate.record_persisted(driver_user_id, lat, lng, now)
          result

        _ ->
          result
      end
    else
      {:ok,
       transient_driver_location(driver_user_id, lat_decimal, lng_decimal, now, cell_token, attrs)}
    end
  end

  defp upsert_driver_location_record(driver_user_id, lat, lng, now, cell_token, attrs) do
    metadata = %{
      "bearing" => PaymentUtils.get_value(attrs, :bearing),
      "speed_kmh" => PaymentUtils.get_value(attrs, :speed_kmh)
    }

    changeset =
      %DriverLocation{}
      |> DriverLocation.create_changeset(%{
        "driver_id" => driver_user_id,
        "lat" => lat,
        "lng" => lng,
        "captured_at" => now,
        "s2_cell_token" => cell_token,
        "metadata" => metadata
      })

    Repo.insert(
      changeset,
      on_conflict: [
        set: [
          lat: lat,
          lng: lng,
          captured_at: now,
          s2_cell_token: cell_token,
          metadata: metadata,
          updated_at: now
        ]
      ],
      conflict_target: [:driver_id]
    )
  end

  defp transient_driver_location(driver_user_id, lat, lng, now, cell_token, attrs) do
    %DriverLocation{
      driver_id: driver_user_id,
      lat: lat,
      lng: lng,
      captured_at: now,
      s2_cell_token: cell_token,
      metadata: %{
        "bearing" => PaymentUtils.get_value(attrs, :bearing),
        "speed_kmh" => PaymentUtils.get_value(attrs, :speed_kmh)
      },
      inserted_at: now,
      updated_at: now
    }
  end

  defp max_last_seen(nil, now), do: now

  defp max_last_seen(last_seen_at, now) do
    if DateTime.compare(last_seen_at, now) == :gt, do: last_seen_at, else: now
  end

  defp measure(stage, timings, fun) do
    stage_started_at = System.monotonic_time()
    result = fun.()
    duration = System.monotonic_time() - stage_started_at
    {result, Map.put(timings, stage, duration)}
  end

  defp normalize_timings(timings) do
    timings
    |> Enum.map(fn {stage, duration} -> {stage, duration_ms(duration)} end)
    |> Enum.sort_by(fn {_stage, duration_ms} -> -duration_ms end)
  end

  defp duration_ms(duration) do
    duration
    |> System.convert_time_unit(:native, :microsecond)
    |> Kernel./(1000.0)
    |> Float.round(2)
  end

  defp parse_coordinate(value, min, max) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} -> validate_coordinate(parsed, min, max)
      _ -> {:error, :invalid_coordinate}
    end
  end

  defp parse_coordinate(value, min, max) when is_float(value),
    do: validate_coordinate(value, min, max)

  defp parse_coordinate(value, min, max) when is_integer(value),
    do: validate_coordinate(value * 1.0, min, max)

  defp parse_coordinate(_value, _min, _max), do: {:error, :invalid_coordinate}

  defp validate_coordinate(value, min, max) when value >= min and value <= max, do: {:ok, value}
  defp validate_coordinate(_value, _min, _max), do: {:error, :invalid_coordinate}

  defp eligible_for_supply?(driver) do
    driver.account_status == "active" and
      driver.verification_status == "approved" and
      driver.subscription_status == "active" and
      driver.is_available == true and
      is_nil(driver.current_ride_id) and
      driver.dispatch_status == "idle"
  end

  defp decimal_to_float(%Decimal{} = value), do: Decimal.to_float(value)
  defp decimal_to_float(value) when is_float(value), do: value
  defp decimal_to_float(value) when is_integer(value), do: value * 1.0
  defp decimal_to_float(_value), do: 0.0
end
