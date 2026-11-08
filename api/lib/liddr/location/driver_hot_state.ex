defmodule Liddr.Location.DriverHotState do
  @moduledoc false

  use GenServer

  import Ecto.Query

  alias Liddr.Accounts.Driver
  alias Liddr.Repo

  @table __MODULE__
  @ttl_ms 2_000
  @prewarm_limit 5_000
  @prewarm_recent_seconds 86_400

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def fetch(driver_user_id) when is_integer(driver_user_id) do
    case lookup(driver_user_id) do
      {:ok, snapshot} -> {:ok, snapshot}
      :miss -> load_and_cache(driver_user_id)
    end
  end

  def fetch(_driver_user_id), do: {:error, :driver_profile_not_found}

  def put(snapshot) when is_map(snapshot) do
    case normalize_snapshot(snapshot) do
      %{user_id: user_id} = normalized ->
        cache_unless_in_transaction(user_id, normalized)

      _ ->
        :ok
    end
  end

  # Updates only the last-seen slot so a location ping cannot extend the TTL of,
  # or overwrite, a snapshot that changed while the ping was running.
  def touch_last_seen(driver_user_id, last_seen_at) when is_integer(driver_user_id) do
    :ets.update_element(@table, driver_user_id, {4, last_seen_at})
    :ok
  end

  def touch_last_seen(_driver_user_id, _last_seen_at), do: :ok

  def invalidate(driver_user_id) when is_integer(driver_user_id) do
    :ets.delete(@table, driver_user_id)
    :ok
  end

  def invalidate(_driver_user_id), do: :ok

  def invalidate_many(driver_user_ids) when is_list(driver_user_ids) do
    Enum.each(driver_user_ids, &invalidate/1)
    :ok
  end

  def invalidate_many(_driver_user_ids), do: :ok

  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end

  def prewarm do
    prewarm_recent_drivers()
  end

  @impl true
  def init(:ok) do
    _ =
      :ets.new(@table, [
        :named_table,
        :public,
        :set,
        {:read_concurrency, true},
        {:write_concurrency, true}
      ])

    {:ok, %{}}
  end

  defp lookup(driver_user_id) do
    now_ms = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, driver_user_id) do
      [{^driver_user_id, expiry_ms, snapshot, last_seen_at}] when expiry_ms > now_ms ->
        {:ok, %{snapshot | last_seen_at: last_seen_at}}

      [{^driver_user_id, _expiry_ms, _snapshot, _last_seen_at}] ->
        :ets.delete(@table, driver_user_id)
        :miss

      [] ->
        :miss
    end
  end

  defp cache_unless_in_transaction(user_id, snapshot) do
    if Repo.in_transaction?() do
      invalidate(user_id)
    else
      :ets.insert(@table, {user_id, expires_at_ms(), snapshot, snapshot.last_seen_at})
      :ok
    end
  end

  defp load_and_cache(driver_user_id) do
    query =
      from(d in Driver,
        where: d.user_id == ^driver_user_id,
        select: %{
          user_id: d.user_id,
          vehicle_category_id: d.vehicle_category_id,
          subscription_status: d.subscription_status,
          is_available: d.is_available,
          account_status: d.account_status,
          verification_status: d.verification_status,
          last_seen_at: d.last_seen_at,
          current_ride_id: d.current_ride_id,
          dispatch_status: d.dispatch_status
        }
      )

    case Repo.one(query) do
      nil ->
        {:error, :driver_profile_not_found}

      snapshot ->
        :ok = put(snapshot)
        {:ok, snapshot}
    end
  end

  defp prewarm_recent_drivers do
    recent_cutoff =
      DateTime.add(DateTime.utc_now() |> DateTime.truncate(:second), -@prewarm_recent_seconds)

    from(
      d in Driver,
      where:
        d.is_available == true or not is_nil(d.current_ride_id) or
          (not is_nil(d.last_seen_at) and d.last_seen_at >= ^recent_cutoff),
      order_by: [desc: d.last_seen_at, desc: d.updated_at],
      limit: ^@prewarm_limit,
      select: %{
        user_id: d.user_id,
        vehicle_category_id: d.vehicle_category_id,
        subscription_status: d.subscription_status,
        is_available: d.is_available,
        account_status: d.account_status,
        verification_status: d.verification_status,
        last_seen_at: d.last_seen_at,
        current_ride_id: d.current_ride_id,
        dispatch_status: d.dispatch_status
      }
    )
    |> Repo.all()
    |> Enum.each(&put/1)

    :ok
  end

  defp normalize_snapshot(snapshot) do
    %{
      user_id: Map.get(snapshot, :user_id) || Map.get(snapshot, "user_id"),
      vehicle_category_id:
        Map.get(snapshot, :vehicle_category_id) || Map.get(snapshot, "vehicle_category_id"),
      subscription_status:
        Map.get(snapshot, :subscription_status) || Map.get(snapshot, "subscription_status"),
      is_available: Map.get(snapshot, :is_available),
      account_status: Map.get(snapshot, :account_status) || Map.get(snapshot, "account_status"),
      verification_status:
        Map.get(snapshot, :verification_status) || Map.get(snapshot, "verification_status"),
      last_seen_at: Map.get(snapshot, :last_seen_at),
      current_ride_id: Map.get(snapshot, :current_ride_id),
      dispatch_status: Map.get(snapshot, :dispatch_status) || Map.get(snapshot, "dispatch_status")
    }
  end

  defp expires_at_ms, do: System.monotonic_time(:millisecond) + @ttl_ms
end
