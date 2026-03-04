defmodule Liddr.Rides.SharedRides.LocationEtaRefresh do
  @moduledoc false

  import Ecto.Query

  alias Liddr.Repo
  alias Liddr.Rides.Realtime
  alias Liddr.Rides.Ride
  alias Liddr.Rides.SharedRideStop
  alias Liddr.Rides.SharedRides.StopPlanner

  @active_statuses ~w(accepted driver_arriving arrived in_progress)
  @default_min_interval_seconds 15

  def maybe_refresh_for_driver(driver_user_id, lat, lng, now)
      when is_integer(driver_user_id) and is_number(lat) and is_number(lng) and
             is_struct(now, DateTime) do
    result =
      Repo.transaction(fn ->
        with {:ok, ride} <- fetch_active_shared_ride_for_driver(driver_user_id),
             :ok <- ensure_refresh_due(ride, now),
             :ok <- ensure_pending_stops(ride.id) do
          _ = StopPlanner.refresh_pending_eta_for_ride!(ride.id, {lat, lng}, now)
          _ = mark_refreshed!(ride, now)
          {:refreshed, ride, fetch_next_pending_stop(ride.id)}
        else
          {:error, reason} -> {:skipped, reason}
        end
      end)

    case result do
      {:ok, {:refreshed, ride, next_stop}} ->
        Realtime.broadcast_shared_eta_updated(ride, next_stop_payload(next_stop))

      _ ->
        :ok
    end

    :ok
  end

  def maybe_refresh_for_driver(_driver_user_id, _lat, _lng, _now), do: :ok

  defp fetch_active_shared_ride_for_driver(driver_user_id) do
    ride =
      Repo.one(
        from r in Ride,
          where:
            r.driver_id == ^driver_user_id and r.product_type == "shared" and
              r.status in ^@active_statuses,
          order_by: [desc: r.updated_at, desc: r.id],
          limit: 1,
          lock: "FOR UPDATE"
      )

    if is_nil(ride), do: {:error, :no_active_shared_ride}, else: {:ok, ride}
  end

  defp ensure_pending_stops(ride_id) do
    pending_count =
      Repo.one(
        from s in SharedRideStop,
          where: s.ride_id == ^ride_id and s.status == "pending",
          select: count(s.id)
      ) || 0

    if pending_count > 0, do: :ok, else: {:error, :no_pending_shared_stops}
  end

  defp fetch_next_pending_stop(ride_id) do
    Repo.one(
      from s in SharedRideStop,
        where: s.ride_id == ^ride_id and s.status == "pending",
        order_by: [asc: s.sequence, asc: s.id],
        limit: 1
    )
  end

  defp ensure_refresh_due(ride, now) do
    min_interval_seconds = min_interval_seconds()

    case parse_refreshed_at(ride.metadata) do
      nil ->
        :ok

      refreshed_at ->
        elapsed_seconds = DateTime.diff(now, refreshed_at, :second)
        if elapsed_seconds >= min_interval_seconds, do: :ok, else: {:error, :refresh_throttled}
    end
  end

  defp mark_refreshed!(ride, now) do
    metadata =
      normalize_metadata(ride.metadata)
      |> Map.put("shared_eta_last_refresh_at", DateTime.to_iso8601(now))

    _ =
      Repo.update_all(
        from(r in Ride, where: r.id == ^ride.id),
        set: [metadata: metadata, updated_at: now]
      )

    :ok
  end

  defp min_interval_seconds do
    config = Application.get_env(:liddr, __MODULE__, [])
    Keyword.get(config, :min_interval_seconds, @default_min_interval_seconds)
  end

  defp parse_refreshed_at(metadata) do
    metadata
    |> normalize_metadata()
    |> Map.get("shared_eta_last_refresh_at")
    |> parse_datetime()
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(String.trim(value)) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp normalize_metadata(%{} = metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}

  defp next_stop_payload(nil), do: nil

  defp next_stop_payload(stop) do
    %{
      "id" => stop.id,
      "member_id" => stop.member_id,
      "stop_type" => stop.stop_type,
      "status" => stop.status,
      "sequence" => stop.sequence,
      "lat" => stop.lat,
      "lng" => stop.lng,
      "eta_at" => stop.eta_at
    }
  end
end
