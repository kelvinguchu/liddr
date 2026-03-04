defmodule Liddr.Rides.Geo do
  alias Decimal, as: D

  @earth_radius_m 6_371_000.0

  def haversine_distance_m(lat1, lng1, lat2, lng2) do
    lat1 = to_float(lat1)
    lng1 = to_float(lng1)
    lat2 = to_float(lat2)
    lng2 = to_float(lng2)

    rad = :math.pi() / 180.0
    d_lat = (lat2 - lat1) * rad
    d_lng = (lng2 - lng1) * rad

    a =
      :math.sin(d_lat / 2) * :math.sin(d_lat / 2) +
        :math.cos(lat1 * rad) * :math.cos(lat2 * rad) *
          :math.sin(d_lng / 2) * :math.sin(d_lng / 2)

    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
    @earth_radius_m * c
  end

  def to_float(%D{} = value), do: D.to_float(value)
  def to_float(value) when is_float(value), do: value
  def to_float(value) when is_integer(value), do: value * 1.0

  def to_float(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> 0.0
    end
  end

  def to_float(_value), do: 0.0
end
