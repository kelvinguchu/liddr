defmodule Liddr.Location.DriverLocationWriteGate do
  @moduledoc false

  use GenServer

  alias Liddr.Rides.Geo

  @table __MODULE__

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def should_persist?(driver_user_id, lat, lng, now)
      when is_integer(driver_user_id) and is_number(lat) and is_number(lng) and
             is_struct(now, DateTime) do
    case :ets.lookup(@table, driver_user_id) do
      [{^driver_user_id, persisted_at, persisted_lat, persisted_lng}] ->
        stale?(persisted_at, now) or moved_far?(persisted_lat, persisted_lng, lat, lng)

      [] ->
        true
    end
  end

  def should_persist?(_driver_user_id, _lat, _lng, _now), do: true

  def record_persisted(driver_user_id, lat, lng, now)
      when is_integer(driver_user_id) and is_number(lat) and is_number(lng) and
             is_struct(now, DateTime) do
    :ets.insert(@table, {driver_user_id, now, lat, lng})
    :ok
  end

  def record_persisted(_driver_user_id, _lat, _lng, _now), do: :ok

  def reset do
    :ets.delete_all_objects(@table)
    :ok
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

  defp stale?(persisted_at, now) do
    DateTime.diff(now, persisted_at, :millisecond) >= min_persist_interval_ms()
  end

  defp moved_far?(persisted_lat, persisted_lng, lat, lng) do
    Geo.haversine_distance_m(persisted_lat, persisted_lng, lat, lng) >= force_persist_distance_m()
  end

  defp min_persist_interval_ms do
    config = Application.get_env(:liddr, __MODULE__, [])
    Keyword.get(config, :min_persist_interval_ms, 1_000)
  end

  defp force_persist_distance_m do
    config = Application.get_env(:liddr, __MODULE__, [])
    Keyword.get(config, :force_persist_distance_m, 25.0)
  end
end
