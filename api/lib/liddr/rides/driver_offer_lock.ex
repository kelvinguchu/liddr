defmodule Liddr.Rides.DriverOfferLock do
  @moduledoc false

  require Logger

  @telemetry_event_acquire [:liddr, :rides, :offer_lock, :acquire]
  @telemetry_event_release [:liddr, :rides, :offer_lock, :release]

  @type acquire_result :: :acquired | :locked | :unavailable

  @callback acquire(driver_id :: integer(), ride_id :: integer(), ttl_seconds :: pos_integer()) ::
              acquire_result()
  @callback release(driver_id :: integer(), ride_id :: integer()) :: :ok

  def acquire(driver_id, ride_id, ttl_seconds) do
    lock_impl().acquire(driver_id, ride_id, ttl_seconds)
  end

  def acquire_many(driver_ids, ride_id, ttl_seconds, opts \\ []) do
    source = normalize_source(Keyword.get(opts, :source, :unknown))
    normalized_driver_ids = normalize_driver_ids(driver_ids)

    normalized_driver_ids
    |> Enum.reduce(
      %{
        source: source,
        ride_id: ride_id,
        selected_driver_ids: [],
        locked_driver_ids: [],
        acquired_count: 0,
        locked_count: 0,
        unavailable_count: 0
      },
      fn driver_id, acc ->
        case acquire(driver_id, ride_id, ttl_seconds) do
          :acquired ->
            emit_acquire_telemetry(source, :acquired)

            %{
              acc
              | acquired_count: acc.acquired_count + 1,
                selected_driver_ids: [driver_id | acc.selected_driver_ids],
                locked_driver_ids: [driver_id | acc.locked_driver_ids]
            }

          :unavailable ->
            emit_acquire_telemetry(source, :unavailable)

            %{
              acc
              | unavailable_count: acc.unavailable_count + 1,
                selected_driver_ids: [driver_id | acc.selected_driver_ids]
            }

          :locked ->
            emit_acquire_telemetry(source, :locked)
            %{acc | locked_count: acc.locked_count + 1}
        end
      end
    )
    |> then(fn result ->
      maybe_log_unavailable_fallback(result)

      %{
        selected_driver_ids: Enum.reverse(result.selected_driver_ids),
        locked_driver_ids: Enum.reverse(result.locked_driver_ids),
        source: result.source,
        ride_id: result.ride_id,
        attempted_count: result.acquired_count + result.locked_count + result.unavailable_count,
        acquired_count: result.acquired_count,
        locked_count: result.locked_count,
        unavailable_count: result.unavailable_count
      }
    end)
  end

  def release_many(items, opts \\ []) do
    source = normalize_source(Keyword.get(opts, :source, :unknown))

    pairs =
      items
      |> List.wrap()
      |> Enum.reduce(MapSet.new(), fn item, acc ->
        case parse_driver_ride_pair(item) do
          {driver_id, ride_id} -> MapSet.put(acc, {driver_id, ride_id})
          nil -> acc
        end
      end)

    Enum.each(pairs, fn {driver_id, ride_id} ->
      _ = release(driver_id, ride_id)
    end)

    emit_release_telemetry(source, MapSet.size(pairs))

    :ok
  end

  def release(driver_id, ride_id), do: lock_impl().release(driver_id, ride_id)

  defp lock_impl do
    Application.get_env(:liddr, :ride_offer_lock, Liddr.Rides.DriverOfferLock.Redis)
  end

  defp maybe_log_unavailable_fallback(%{
         unavailable_count: count,
         source: source,
         ride_id: ride_id
       })
       when count > 0 do
    Logger.warning(
      "[rides.offer_lock] source=#{source} ride_id=#{ride_id} lock_backend=unavailable fallback=allow_without_lock count=#{count}"
    )
  end

  defp maybe_log_unavailable_fallback(_result), do: :ok

  defp emit_acquire_telemetry(source, result) do
    :telemetry.execute(@telemetry_event_acquire, %{count: 1}, %{source: source, result: result})
  end

  defp emit_release_telemetry(source, count) do
    :telemetry.execute(@telemetry_event_release, %{count: count}, %{source: source})
  end

  defp normalize_driver_ids(driver_ids) do
    driver_ids
    |> List.wrap()
    |> Enum.flat_map(fn
      value when is_integer(value) and value > 0 -> [value]
      value when is_binary(value) -> maybe_parse_int(value)
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp parse_driver_ride_pair({driver_id, ride_id}) do
    with {:ok, parsed_driver_id} <- parse_positive_int(driver_id),
         {:ok, parsed_ride_id} <- parse_positive_int(ride_id) do
      {parsed_driver_id, parsed_ride_id}
    else
      _ -> nil
    end
  end

  defp parse_driver_ride_pair(%{driver_id: driver_id, ride_id: ride_id}),
    do: parse_driver_ride_pair({driver_id, ride_id})

  defp parse_driver_ride_pair(%{"driver_id" => driver_id, "ride_id" => ride_id}),
    do: parse_driver_ride_pair({driver_id, ride_id})

  defp parse_driver_ride_pair(_item), do: nil

  defp parse_positive_int(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_positive_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> :error
    end
  end

  defp parse_positive_int(_value), do: :error

  defp normalize_source(source) when is_atom(source), do: Atom.to_string(source)

  defp normalize_source(source) when is_binary(source) do
    source
    |> String.trim()
    |> case do
      "" -> "unknown"
      value -> value
    end
  end

  defp normalize_source(_source), do: "unknown"

  defp maybe_parse_int(value) do
    case parse_positive_int(value) do
      {:ok, parsed} -> [parsed]
      :error -> []
    end
  end
end
