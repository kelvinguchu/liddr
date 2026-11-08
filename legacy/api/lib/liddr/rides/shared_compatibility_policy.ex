defmodule Liddr.Rides.SharedCompatibilityPolicy do
  @moduledoc false

  alias Liddr.Rides.Geo

  @max_pickup_distance_m 2_500.0
  @max_dropoff_distance_m 5_000.0
  @max_route_corridor_m 1_200.0
  @min_progress_delta 0.02
  @max_candidate_age_seconds 1_800
  @pickup_weight 0.55
  @dropoff_weight 0.35
  @freshness_weight 0.10

  def evaluate(candidate, request, now) when is_map(candidate) and is_map(request) do
    with :ok <- ensure_open_capacity(candidate),
         {:ok, pickup_distance_m} <- distance_between(candidate, request, :pickup),
         :ok <- within_limit(pickup_distance_m, @max_pickup_distance_m, :pickup_too_far),
         {:ok, dropoff_distance_m} <- distance_between(candidate, request, :dropoff),
         :ok <- within_limit(dropoff_distance_m, @max_dropoff_distance_m, :dropoff_too_far),
         {:ok, alignment} <- route_alignment(candidate, request),
         {:ok, age_seconds} <- candidate_age_seconds(candidate, now),
         :ok <- within_limit(age_seconds * 1.0, @max_candidate_age_seconds * 1.0, :ride_too_old) do
      pickup_score = proximity_score(pickup_distance_m, @max_pickup_distance_m)
      dropoff_score = proximity_score(dropoff_distance_m, @max_dropoff_distance_m)
      freshness_score = 1.0 - age_seconds / @max_candidate_age_seconds

      score =
        pickup_score * @pickup_weight +
          dropoff_score * @dropoff_weight +
          max(min(freshness_score, 1.0), 0.0) * @freshness_weight

      {:ok,
       %{
         ride_id: candidate.ride_id,
         group_id: candidate.group_id,
         score: Float.round(score, 4),
         pickup_distance_m: pickup_distance_m,
         dropoff_distance_m: dropoff_distance_m,
         route_pickup_distance_m: alignment.pickup_to_route_m,
         route_dropoff_distance_m: alignment.dropoff_to_route_m,
         pickup_progress: alignment.pickup_progress,
         dropoff_progress: alignment.dropoff_progress,
         age_seconds: age_seconds,
         open_seats: candidate.open_seats
       }}
    end
  end

  defp ensure_open_capacity(%{open_seats: open_seats})
       when is_integer(open_seats) and open_seats > 0,
       do: :ok

  defp ensure_open_capacity(_candidate), do: {:error, :group_full}

  defp distance_between(candidate, request, :pickup) do
    distance(
      candidate.pickup_lat,
      candidate.pickup_lng,
      request.pickup_lat,
      request.pickup_lng,
      :invalid_pickup_coordinates
    )
  end

  defp distance_between(candidate, request, :dropoff) do
    distance(
      candidate.dropoff_lat,
      candidate.dropoff_lng,
      request.dropoff_lat,
      request.dropoff_lng,
      :invalid_dropoff_coordinates
    )
  end

  defp distance(lat1, lng1, lat2, lng2, error_code) do
    if coordinates?(lat1, lng1) and coordinates?(lat2, lng2) do
      {:ok, Geo.haversine_distance_m(lat1, lng1, lat2, lng2)}
    else
      {:error, error_code}
    end
  end

  defp coordinates?(lat, lng), do: is_number(lat) and is_number(lng)

  defp within_limit(value, limit, _error_code) when is_number(value) and value <= limit, do: :ok
  defp within_limit(_value, _limit, error_code), do: {:error, error_code}

  defp candidate_age_seconds(%{requested_at: %DateTime{} = requested_at}, %DateTime{} = now),
    do: {:ok, max(DateTime.diff(now, requested_at, :second), 0)}

  defp candidate_age_seconds(_candidate, _now), do: {:ok, 0}

  defp proximity_score(distance_m, max_distance_m) when max_distance_m > 0 do
    score = 1.0 - distance_m / max_distance_m
    max(min(score, 1.0), 0.0)
  end

  defp route_alignment(candidate, request) do
    segment =
      segment_points(
        candidate.pickup_lat,
        candidate.pickup_lng,
        candidate.dropoff_lat,
        candidate.dropoff_lng
      )

    with {:ok, pickup_projection} <-
           point_projection(segment, request.pickup_lat, request.pickup_lng),
         {:ok, dropoff_projection} <-
           point_projection(segment, request.dropoff_lat, request.dropoff_lng),
         :ok <-
           within_limit(
             pickup_projection.distance_m,
             @max_route_corridor_m,
             :pickup_out_of_route_corridor
           ),
         :ok <-
           within_limit(
             dropoff_projection.distance_m,
             @max_route_corridor_m,
             :dropoff_out_of_route_corridor
           ),
         :ok <- ensure_forward_progress(pickup_projection.progress, dropoff_projection.progress) do
      {:ok,
       %{
         pickup_to_route_m: pickup_projection.distance_m,
         dropoff_to_route_m: dropoff_projection.distance_m,
         pickup_progress: pickup_projection.progress,
         dropoff_progress: dropoff_projection.progress
       }}
    end
  end

  defp segment_points(lat1, lng1, lat2, lng2) do
    %{
      from: %{lat: lat1, lng: lng1},
      to: %{lat: lat2, lng: lng2},
      lat0_rad: deg_to_rad((lat1 + lat2) / 2.0)
    }
  end

  defp point_projection(segment, lat, lng) do
    from = to_xy(segment.from.lat, segment.from.lng, segment.lat0_rad)
    to = to_xy(segment.to.lat, segment.to.lng, segment.lat0_rad)
    point = to_xy(lat, lng, segment.lat0_rad)
    vector = %{x: to.x - from.x, y: to.y - from.y}
    vector_norm_sq = vector.x * vector.x + vector.y * vector.y

    if vector_norm_sq <= 1.0 do
      {:error, :invalid_route_geometry}
    else
      raw_progress =
        ((point.x - from.x) * vector.x + (point.y - from.y) * vector.y) / vector_norm_sq

      clamped_progress = max(min(raw_progress, 1.0), 0.0)

      closest = %{
        x: from.x + clamped_progress * vector.x,
        y: from.y + clamped_progress * vector.y
      }

      distance_m =
        :math.sqrt(:math.pow(point.x - closest.x, 2) + :math.pow(point.y - closest.y, 2))

      {:ok, %{distance_m: distance_m, progress: clamped_progress}}
    end
  end

  defp ensure_forward_progress(pickup_progress, dropoff_progress) do
    if dropoff_progress + 0.0001 >= pickup_progress + @min_progress_delta,
      do: :ok,
      else: {:error, :reverse_direction}
  end

  defp to_xy(lat, lng, lat0_rad) do
    radius = 6_371_000.0
    x = radius * deg_to_rad(lng) * :math.cos(lat0_rad)
    y = radius * deg_to_rad(lat)
    %{x: x, y: y}
  end

  defp deg_to_rad(value), do: value * :math.pi() / 180.0
end
