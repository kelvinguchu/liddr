defmodule Liddr.Location.Cells do
  @moduledoc false

  @default_cell_size_deg 0.01
  @min_cell_size_deg 0.001
  @max_cell_size_deg 0.1

  def token(lat, lng, opts \\ [])

  def token(lat, lng, opts) when is_number(lat) and is_number(lng) do
    cell_size_deg = resolve_cell_size_deg(opts)
    {lat_idx, lng_idx} = cell_indexes(lat, lng, cell_size_deg)
    "grid:#{lat_idx}:#{lng_idx}"
  end

  def token(_lat, _lng, _opts), do: nil

  def neighboring_tokens(lat, lng, ring_radius, opts \\ [])

  def neighboring_tokens(lat, lng, ring_radius, opts)
      when is_number(lat) and is_number(lng) and is_integer(ring_radius) and ring_radius >= 0 do
    cell_size_deg = resolve_cell_size_deg(opts)
    {lat_idx, lng_idx} = cell_indexes(lat, lng, cell_size_deg)

    for lat_delta <- -ring_radius..ring_radius,
        lng_delta <- -ring_radius..ring_radius do
      "grid:#{lat_idx + lat_delta}:#{lng_idx + lng_delta}"
    end
  end

  def neighboring_tokens(_lat, _lng, _ring_radius, _opts), do: []

  def ring_radius_for_km(radius_km, opts \\ [])

  def ring_radius_for_km(radius_km, opts) when is_number(radius_km) and radius_km >= 0 do
    cell_size_deg = resolve_cell_size_deg(opts)
    cell_km = cell_size_deg * 111.0
    ceil(radius_km / max(cell_km, 0.01))
  end

  def ring_radius_for_km(_radius_km, _opts), do: 0

  defp cell_indexes(lat, lng, cell_size_deg) do
    lat_idx = floor((lat + 90.0) / cell_size_deg)
    lng_idx = floor((lng + 180.0) / cell_size_deg)
    {lat_idx, lng_idx}
  end

  defp resolve_cell_size_deg(opts) do
    configured =
      opts[:cell_size_deg] || Application.get_env(:liddr, __MODULE__, [])[:cell_size_deg] ||
        @default_cell_size_deg

    cond do
      is_float(configured) or is_integer(configured) ->
        (configured * 1.0)
        |> max(@min_cell_size_deg)
        |> min(@max_cell_size_deg)

      true ->
        @default_cell_size_deg
    end
  end
end
