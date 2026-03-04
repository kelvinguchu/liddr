defmodule Liddr.Rides.Execution.Shared do
  import Ecto.Query

  alias Liddr.Accounts.Driver
  alias Liddr.Repo
  alias Liddr.Rides.Ride
  alias Liddr.Subscriptions.PaymentUtils

  def ensure_rider_owns_ride!(ride, rider_user_id) do
    if ride.rider_id == rider_user_id, do: :ok, else: Repo.rollback(:ride_not_assigned_to_rider)
  end

  def ensure_driver_owns_ride!(ride, driver_user_id) do
    if ride.driver_id == driver_user_id,
      do: :ok,
      else: Repo.rollback(:ride_not_assigned_to_driver)
  end

  def ensure_driver_locked_to_ride!(driver, ride_id) do
    if driver.current_ride_id == ride_id, do: :ok, else: Repo.rollback(:driver_not_locked_to_ride)
  end

  def fetch_ride_for_update!(ride_id) do
    parsed_ride_id = parse_positive_integer(ride_id) || Repo.rollback(:ride_not_found)

    Repo.one(from r in Ride, where: r.id == ^parsed_ride_id, lock: "FOR UPDATE") ||
      Repo.rollback(:ride_not_found)
  end

  def fetch_driver_for_update!(driver_user_id) do
    Repo.one(from d in Driver, where: d.user_id == ^driver_user_id, lock: "FOR UPDATE") ||
      Repo.rollback(:driver_profile_not_found)
  end

  def update_ride!(ride, attrs) do
    ride
    |> Ride.create_changeset(attrs)
    |> Repo.update()
    |> unwrap_or_rollback()
  end

  def update_driver_dispatch!(driver, dispatch_status, now) do
    driver
    |> Driver.create_changeset(%{"dispatch_status" => dispatch_status, "last_seen_at" => now})
    |> Repo.update()
    |> unwrap_or_rollback()
  end

  def unlock_driver!(driver, now) do
    driver
    |> Driver.create_changeset(%{
      "current_ride_id" => nil,
      "dispatch_status" => "idle",
      "is_available" => true,
      "last_seen_at" => now
    })
    |> Repo.update()
    |> unwrap_or_rollback()
  end

  def release_driver_after_cancellation!(driver, now, opts \\ %{}) do
    keep_unavailable =
      Map.get(opts, :keep_unavailable) || Map.get(opts, "keep_unavailable") || false

    attrs = %{
      "current_ride_id" => nil,
      "dispatch_status" => "idle",
      "is_available" => not keep_unavailable,
      "last_seen_at" => now
    }

    driver
    |> Driver.create_changeset(attrs)
    |> Repo.update()
    |> unwrap_or_rollback()
  end

  def maybe_unlock_assigned_driver!(ride, now) do
    if is_integer(ride.driver_id) do
      driver = fetch_driver_for_update!(ride.driver_id)
      if driver.current_ride_id == ride.id, do: unlock_driver!(driver, now).user_id, else: nil
    else
      nil
    end
  end

  def cancellation_reason(ride) do
    ride.metadata
    |> normalize_metadata()
    |> case do
      metadata ->
        Map.get(metadata, "cancel_reason_code") || Map.get(metadata, "cancel_reason")
    end
  end

  def normalize_metadata(%{} = metadata), do: metadata
  def normalize_metadata(_metadata), do: %{}

  def extract_cancel_reason(attrs) do
    attrs
    |> PaymentUtils.get_value(:reason)
    |> PaymentUtils.normalize_text()
    |> case do
      nil -> {:error, :missing}
      reason -> {:ok, reason}
    end
  end

  def unwrap_transaction_result({:ok, payload}), do: {:ok, payload}
  def unwrap_transaction_result({:error, reason}), do: {:error, reason}
  def unwrap_or_rollback({:ok, value}), do: value
  def unwrap_or_rollback({:error, changeset}), do: Repo.rollback(changeset)

  def parse_positive_integer(value) when is_integer(value) and value > 0, do: value

  def parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  def parse_positive_integer(_value), do: nil
end
