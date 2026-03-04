defmodule Liddr.DriverAvailability do
  @moduledoc false

  import Ecto.Query

  alias Liddr.Accounts.Driver
  alias Liddr.Location
  alias Liddr.Repo
  alias Liddr.Verification.DriverActivityEvent

  def go_online(driver_user_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    case Repo.transaction(fn ->
           driver = fetch_driver_for_update!(driver_user_id)
           ensure_driver_online_eligible!(driver)
           update_driver_availability!(driver, true, now)
         end)
         |> unwrap_transaction_result() do
      {:ok, driver} = ok ->
        _ = Location.sync_driver_supply(driver.user_id)
        ok

      error ->
        error
    end
  end

  def go_offline(driver_user_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    case Repo.transaction(fn ->
           driver = fetch_driver_for_update!(driver_user_id)
           update_driver_availability!(driver, false, now)
         end)
         |> unwrap_transaction_result() do
      {:ok, driver} = ok ->
        _ = Location.remove_driver_from_supply(driver.user_id)
        ok

      error ->
        error
    end
  end

  defp fetch_driver_for_update!(driver_user_id) do
    Repo.one(
      from d in Driver,
        where: d.user_id == ^driver_user_id,
        lock: "FOR UPDATE"
    ) || Repo.rollback(:driver_profile_not_found)
  end

  defp ensure_driver_online_eligible!(driver) do
    cond do
      driver.account_status != "active" ->
        Repo.rollback(:driver_account_not_active)

      driver.verification_status != "approved" ->
        Repo.rollback(:driver_not_verified)

      driver.subscription_status != "active" ->
        Repo.rollback(:driver_subscription_not_active)

      not is_nil(driver.current_ride_id) ->
        Repo.rollback(:driver_has_active_ride)

      true ->
        :ok
    end
  end

  defp update_driver_availability!(driver, is_available, now) do
    previous_value = if driver.is_available, do: "online", else: "offline"
    new_value = if is_available, do: "online", else: "offline"

    attrs =
      %{
        "is_available" => is_available,
        "dispatch_status" => if(is_available, do: "idle", else: driver.dispatch_status || "idle"),
        "last_seen_at" => now
      }
      |> maybe_put_last_online_at(is_available, now, driver.last_online_at)

    updated_driver =
      driver
      |> Driver.create_changeset(attrs)
      |> Repo.update()
      |> case do
        {:ok, value} -> value
        {:error, changeset} -> Repo.rollback(changeset)
      end

    event_type = if is_available, do: "went_online", else: "went_offline"

    %DriverActivityEvent{}
    |> DriverActivityEvent.create_changeset(%{
      "driver_id" => driver.user_id,
      "event_type" => event_type,
      "previous_value" => previous_value,
      "new_value" => new_value,
      "reason_code" => "driver_presence_toggle",
      "actor_type" => "driver",
      "actor_user_id" => driver.user_id,
      "payload" => %{"is_available" => is_available}
    })
    |> Repo.insert()
    |> case do
      {:ok, _event} -> updated_driver
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp maybe_put_last_online_at(attrs, true, now, _existing),
    do: Map.put(attrs, "last_online_at", now)

  defp maybe_put_last_online_at(attrs, false, _now, _existing), do: attrs

  defp unwrap_transaction_result({:ok, value}), do: {:ok, value}
  defp unwrap_transaction_result({:error, reason}), do: {:error, reason}
end
