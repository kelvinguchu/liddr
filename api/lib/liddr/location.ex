defmodule Liddr.Location do
  @moduledoc false

  alias Liddr.Accounts.Driver
  alias Liddr.Location.Cells
  alias Liddr.Location.DriverLocation
  alias Liddr.Location.SupplyIndex
  alias Liddr.Repo
  alias Liddr.Rides.SharedRides.LocationEtaRefresh
  alias Liddr.Subscriptions.PaymentUtils

  def upsert_driver_location(driver_user_id, attrs \\ %{}) do
    with %Driver{} <- Repo.get(Driver, driver_user_id),
         {:ok, lat} <- parse_coordinate(PaymentUtils.get_value(attrs, :lat), -90.0, 90.0),
         {:ok, lng} <- parse_coordinate(PaymentUtils.get_value(attrs, :lng), -180.0, 180.0) do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      lat_decimal = Decimal.from_float(lat) |> Decimal.round(7)
      lng_decimal = Decimal.from_float(lng) |> Decimal.round(7)
      cell_token = Cells.token(lat, lng)

      changeset =
        %DriverLocation{}
        |> DriverLocation.create_changeset(%{
          "driver_id" => driver_user_id,
          "lat" => lat_decimal,
          "lng" => lng_decimal,
          "captured_at" => now,
          "s2_cell_token" => cell_token,
          "metadata" => %{
            "bearing" => PaymentUtils.get_value(attrs, :bearing),
            "speed_kmh" => PaymentUtils.get_value(attrs, :speed_kmh)
          }
        })

      Repo.insert(
        changeset,
        on_conflict: [
          set: [
            lat: lat_decimal,
            lng: lng_decimal,
            captured_at: now,
            s2_cell_token: cell_token,
            metadata: %{
              "bearing" => PaymentUtils.get_value(attrs, :bearing),
              "speed_kmh" => PaymentUtils.get_value(attrs, :speed_kmh)
            },
            updated_at: now
          ]
        ],
        conflict_target: [:driver_id]
      )
      |> case do
        {:ok, _location} = result ->
          _ = sync_driver_supply(driver_user_id)
          _ = LocationEtaRefresh.maybe_refresh_for_driver(driver_user_id, lat, lng, now)
          result

        {:error, _changeset} = error ->
          error
      end
    else
      nil -> {:error, :driver_profile_not_found}
      {:error, _reason} -> {:error, :invalid_driver_location}
    end
  end

  def sync_driver_supply(driver_user_id) when is_integer(driver_user_id) do
    driver = Repo.get(Driver, driver_user_id)
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
          location.captured_at
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
