defmodule Liddr.Location.SupplyIndex do
  @moduledoc false

  alias Liddr.Location.Redis
  alias Liddr.Location.S2

  @default_zone_ttl_seconds 180
  @default_driver_ttl_seconds 180
  @default_lookup_cell_limit 225

  def upsert_driver(driver_user_id, vehicle_category_id, lat, lng, captured_at)
      when is_integer(driver_user_id) and is_integer(vehicle_category_id) do
    upsert_driver(
      driver_user_id,
      vehicle_category_id,
      lat,
      lng,
      captured_at,
      s2_module().token(lat, lng)
    )
  end

  def upsert_driver(_driver_user_id, _vehicle_category_id, _lat, _lng, _captured_at), do: :ok

  def upsert_driver(driver_user_id, vehicle_category_id, lat, lng, captured_at, cell_token)
      when is_integer(driver_user_id) and is_integer(vehicle_category_id) do
    now_iso = datetime_to_iso8601(captured_at)

    with true <- is_binary(cell_token),
         {:ok, previous} <- fetch_driver_snapshot(driver_user_id),
         commands <-
           upsert_commands(
             driver_user_id,
             vehicle_category_id,
             cell_token,
             lat,
             lng,
             now_iso,
             previous
           ),
         {:ok, _} <- redis_module().pipeline(commands) do
      :ok
    else
      _ -> :ok
    end
  end

  def upsert_driver(_driver_user_id, _vehicle_category_id, _lat, _lng, _captured_at, _cell_token),
    do: :ok

  def remove_driver(driver_user_id) when is_integer(driver_user_id) do
    with {:ok, previous} <- fetch_driver_snapshot(driver_user_id),
         commands <- remove_commands(driver_user_id, previous),
         {:ok, _} <- redis_module().pipeline(commands) do
      :ok
    else
      _ -> :ok
    end
  end

  def remove_driver(_driver_user_id), do: :ok

  def candidate_driver_ids(vehicle_category_id, lat, lng, radius_km, max_candidates)
      when is_integer(vehicle_category_id) and is_number(lat) and is_number(lng) do
    with {:ok, cells} <- covering_tokens(lat, lng, radius_km),
         {:ok, ids} <-
           cells
           |> zone_commands(vehicle_category_id)
           |> fetch_candidate_ids(max_candidates) do
      {:ok, ids}
    else
      {:error, :invalid_coordinates} -> {:error, :invalid_supply_lookup}
      {:error, _reason} -> {:error, :supply_index_unavailable}
    end
  end

  def candidate_driver_ids(_vehicle_category_id, _lat, _lng, _radius_km, _max_candidates),
    do: {:error, :invalid_supply_lookup}

  defp fetch_driver_snapshot(driver_user_id) do
    case redis_module().command(["HGETALL", driver_key(driver_user_id)]) do
      {:ok, fields} when is_list(fields) ->
        {:ok, map_from_hgetall(fields)}

      _ ->
        {:ok, %{}}
    end
  end

  defp upsert_commands(
         driver_user_id,
         vehicle_category_id,
         cell_token,
         lat,
         lng,
         captured_at_iso,
         previous
       ) do
    zone_ttl_seconds = zone_ttl_seconds()
    driver_ttl_seconds = driver_ttl_seconds()
    new_zone = zone_key(cell_token, vehicle_category_id)

    commands = [
      ["SADD", new_zone, driver_user_id],
      ["EXPIRE", new_zone, zone_ttl_seconds],
      [
        "HSET",
        driver_key(driver_user_id),
        "vehicle_category_id",
        vehicle_category_id,
        "cell",
        cell_token,
        "lat",
        lat,
        "lng",
        lng,
        "captured_at",
        captured_at_iso
      ],
      ["EXPIRE", driver_key(driver_user_id), driver_ttl_seconds]
    ]

    old_zone_removal(previous, new_zone, driver_user_id) ++ commands
  end

  defp remove_commands(driver_user_id, previous) do
    old_zone_removal(previous, nil, driver_user_id) ++ [["DEL", driver_key(driver_user_id)]]
  end

  defp old_zone_removal(previous, new_zone, driver_user_id) do
    case previous_zone(previous) do
      nil -> []
      ^new_zone -> []
      old_zone -> [["SREM", old_zone, driver_user_id]]
    end
  end

  defp previous_zone(previous) do
    old_cell = previous["cell"]
    old_category_id = parse_positive_integer(previous["vehicle_category_id"])

    if is_binary(old_cell) and is_integer(old_category_id) do
      zone_key(old_cell, old_category_id)
    end
  end

  defp map_from_hgetall(fields) do
    fields
    |> Enum.chunk_every(2)
    |> Enum.reduce(%{}, fn
      [key, value], acc -> Map.put(acc, to_string(key), value)
      _pair, acc -> acc
    end)
  end

  defp driver_key(driver_user_id), do: "driver:supply:#{driver_user_id}"
  defp zone_key(cell_token, category_id), do: "zone:#{cell_token}:supply:#{category_id}"

  defp zone_commands(cells, vehicle_category_id) do
    Enum.map(cells, fn cell_token -> ["SMEMBERS", zone_key(cell_token, vehicle_category_id)] end)
  end

  defp fetch_candidate_ids([], _max_candidates), do: {:ok, []}

  defp fetch_candidate_ids(commands, max_candidates) do
    case redis_module().pipeline(commands) do
      {:ok, rows} ->
        {:ok,
         rows
         |> List.wrap()
         |> Enum.flat_map(&List.wrap/1)
         |> Enum.map(&parse_positive_integer/1)
         |> Enum.reject(&is_nil/1)
         |> Enum.uniq()
         |> Enum.take(max(max_candidates, 1))}

      _ ->
        {:error, :supply_index_unavailable}
    end
  end

  defp covering_tokens(lat, lng, radius_km) do
    s2_module().covering_tokens(lat, lng, radius_km, lookup_cell_limit())
  end

  defp datetime_to_iso8601(%DateTime{} = captured_at), do: DateTime.to_iso8601(captured_at)

  defp datetime_to_iso8601(_captured_at),
    do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: value

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp parse_positive_integer(_value), do: nil

  defp s2_module do
    Application.get_env(:liddr, :location_s2_module, S2)
  end

  defp redis_module do
    Application.get_env(:liddr, :location_redis_module, Redis)
  end

  defp zone_ttl_seconds do
    Application.get_env(:liddr, __MODULE__, [])[:zone_ttl_seconds] || @default_zone_ttl_seconds
  end

  defp driver_ttl_seconds do
    Application.get_env(:liddr, __MODULE__, [])[:driver_ttl_seconds] ||
      @default_driver_ttl_seconds
  end

  defp lookup_cell_limit do
    Application.get_env(:liddr, __MODULE__, [])[:lookup_cell_limit] || @default_lookup_cell_limit
  end
end
