defmodule Liddr.Location.SupplyIndex do
  @moduledoc false

  alias Liddr.Location.Cells
  alias Liddr.Location.Redis

  @default_zone_ttl_seconds 180
  @default_driver_ttl_seconds 180
  @default_lookup_cell_limit 225

  def upsert_driver(driver_user_id, vehicle_category_id, lat, lng, captured_at)
      when is_integer(driver_user_id) and is_integer(vehicle_category_id) do
    cell_token = Cells.token(lat, lng)
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
         {:ok, _} <- Redis.pipeline(commands) do
      :ok
    else
      _ -> :ok
    end
  end

  def upsert_driver(_driver_user_id, _vehicle_category_id, _lat, _lng, _captured_at), do: :ok

  def remove_driver(driver_user_id) when is_integer(driver_user_id) do
    with {:ok, previous} <- fetch_driver_snapshot(driver_user_id),
         commands <- remove_commands(driver_user_id, previous),
         {:ok, _} <- Redis.pipeline(commands) do
      :ok
    else
      _ -> :ok
    end
  end

  def remove_driver(_driver_user_id), do: :ok

  def candidate_driver_ids(vehicle_category_id, lat, lng, radius_km, max_candidates)
      when is_integer(vehicle_category_id) and is_number(lat) and is_number(lng) do
    ring_radius = Cells.ring_radius_for_km(radius_km)

    cells =
      Cells.neighboring_tokens(lat, lng, ring_radius)
      |> Enum.take(lookup_cell_limit())

    commands =
      Enum.map(cells, fn cell_token ->
        ["SMEMBERS", zone_key(cell_token, vehicle_category_id)]
      end)

    case Redis.pipeline(commands) do
      {:ok, rows} ->
        ids =
          rows
          |> List.wrap()
          |> Enum.flat_map(&List.wrap/1)
          |> Enum.map(&parse_positive_integer/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()
          |> Enum.take(max(max_candidates, 1))

        {:ok, ids}

      _ ->
        {:error, :supply_index_unavailable}
    end
  end

  def candidate_driver_ids(_vehicle_category_id, _lat, _lng, _radius_km, _max_candidates),
    do: {:error, :invalid_supply_lookup}

  defp fetch_driver_snapshot(driver_user_id) do
    case Redis.command(["HGETALL", driver_key(driver_user_id)]) do
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
    old_cell = previous["cell"]
    old_category_id = parse_positive_integer(previous["vehicle_category_id"])

    old_zone =
      if is_binary(old_cell) and is_integer(old_category_id),
        do: zone_key(old_cell, old_category_id),
        else: nil

    new_zone = zone_key(cell_token, vehicle_category_id)

    []
    |> maybe_prepend_old_zone_removal(old_zone, new_zone, driver_user_id)
    |> Kernel.++([
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
    ])
  end

  defp remove_commands(driver_user_id, previous) do
    old_cell = previous["cell"]
    old_category_id = parse_positive_integer(previous["vehicle_category_id"])

    commands =
      if is_binary(old_cell) and is_integer(old_category_id) do
        [["SREM", zone_key(old_cell, old_category_id), driver_user_id]]
      else
        []
      end

    commands ++ [["DEL", driver_key(driver_user_id)]]
  end

  defp maybe_prepend_old_zone_removal(commands, nil, _new_zone, _driver_user_id), do: commands

  defp maybe_prepend_old_zone_removal(commands, old_zone, new_zone, driver_user_id) do
    if old_zone == new_zone do
      commands
    else
      [["SREM", old_zone, driver_user_id] | commands]
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
