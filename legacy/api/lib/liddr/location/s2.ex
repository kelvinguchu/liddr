defmodule Liddr.Location.S2 do
  @moduledoc false

  import Bitwise

  alias Liddr.Location.S2Native

  @default_level 13
  @min_level 1
  @max_level 30

  def token(lat, lng) when is_number(lat) and is_number(lng) do
    with {:ok, normalized_lat, normalized_lng} <- normalize_coordinates(lat, lng),
         {:ok, face, i, j} <- face_ij(normalized_lat, normalized_lng) do
      level = configured_level()

      Liddr.Location.S2Hilbert.cell_id(face, i, j, level)
      |> Liddr.Location.S2Hilbert.token()
    else
      _ -> nil
    end
  end

  def token(_lat, _lng), do: nil

  def covering_tokens(lat, lng, radius_km, max_cells \\ nil)

  def covering_tokens(lat, lng, radius_km, max_cells)
      when is_number(lat) and is_number(lng) and is_number(radius_km) and radius_km >= 0 do
    with {:ok, normalized_lat, normalized_lng} <- normalize_coordinates(lat, lng),
         {:ok, tokens} <-
           S2Native.covering_tokens(
             normalized_lat,
             normalized_lng,
             radius_km,
             configured_level(),
             max_cells
           ) do
      {:ok, tokens}
    else
      {:error, _reason} -> {:error, :s2_covering_unavailable}
      _ -> {:error, :invalid_coordinates}
    end
  end

  def covering_tokens(_lat, _lng, _radius_km, _max_cells), do: {:error, :invalid_coordinates}

  defp face_ij(lat, lng) do
    {x, y, z} = xyz(lat, lng)
    {face, u, v} = xyz_to_face_uv(x, y, z)
    size = 1 <<< 30
    i = axis_index(uv_to_st(u), size)
    j = axis_index(uv_to_st(v), size)
    {:ok, face, i, j}
  end

  defp xyz(lat, lng) do
    lat_rad = deg_to_rad(lat)
    lng_rad = deg_to_rad(lng)
    cos_lat = :math.cos(lat_rad)
    {cos_lat * :math.cos(lng_rad), cos_lat * :math.sin(lng_rad), :math.sin(lat_rad)}
  end

  defp xyz_to_face_uv(x, y, z) do
    ax = abs(x)
    ay = abs(y)
    az = abs(z)

    cond do
      ax >= ay and ax >= az and x >= 0 -> {0, y / x, z / x}
      ax >= ay and ax >= az -> {3, z / x, y / x}
      ay >= ax and ay >= az and y >= 0 -> {1, -x / y, z / y}
      ay >= ax and ay >= az -> {4, z / y, -x / y}
      z >= 0 -> {2, -x / z, -y / z}
      true -> {5, -y / z, -x / z}
    end
  end

  defp uv_to_st(value) when value >= 0, do: 0.5 * :math.sqrt(1 + 3 * value)
  defp uv_to_st(value), do: 1 - 0.5 * :math.sqrt(1 - 3 * value)

  defp axis_index(st, size) do
    st
    |> min(1.0 - 1.0e-12)
    |> max(0.0)
    |> Kernel.*(size)
    |> floor()
    |> min(size - 1)
  end

  defp normalize_coordinates(lat, lng) when lat >= -90 and lat <= 90 do
    {:ok, lat * 1.0, normalize_lng(lng * 1.0)}
  end

  defp normalize_coordinates(_lat, _lng), do: {:error, :invalid_coordinates}

  defp normalize_lng(lng) when lng > 180.0, do: normalize_lng(lng - 360.0)
  defp normalize_lng(lng) when lng < -180.0, do: normalize_lng(lng + 360.0)
  defp normalize_lng(lng), do: lng

  defp deg_to_rad(deg), do: deg * :math.pi() / 180.0

  defp configured_level do
    Application.get_env(:liddr, __MODULE__, [])
    |> Keyword.get(:level, @default_level)
    |> clamp_level()
  end

  defp clamp_level(level) when is_integer(level), do: min(max(level, @min_level), @max_level)
  defp clamp_level(level) when is_float(level), do: clamp_level(round(level))
  defp clamp_level(_level), do: @default_level
end
