defmodule Liddr.Rides.CandidatePool do
  @moduledoc false

  alias Liddr.Location.SupplyIndex
  alias Liddr.Rides.VehicleCategory

  @fallback_error_codes ~w(supply_index_unavailable invalid_supply_lookup redis_unavailable)

  def prefilter_driver_ids(%VehicleCategory{} = category, pickup, limit, radius_km, opts \\ []) do
    supply_index =
      opts[:supply_index] || Application.get_env(:liddr, :ride_supply_index, SupplyIndex)

    max_candidates = max(limit * 8, 20)

    case supply_index.candidate_driver_ids(
           category.id,
           pickup.lat,
           pickup.lng,
           radius_km,
           max_candidates
         ) do
      {:ok, ids} when is_list(ids) ->
        {:ok,
         ids
         |> Enum.map(&parse_positive_integer/1)
         |> Enum.reject(&is_nil/1)
         |> Enum.uniq()}

      {:error, reason} ->
        if to_string(reason) in @fallback_error_codes,
          do: {:fallback, reason},
          else: {:error, reason}

      _ ->
        {:fallback, :supply_index_unavailable}
    end
  end

  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: value

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp parse_positive_integer(_value), do: nil
end
