defmodule Liddr.Rides.CandidateSelection do
  import Ecto.Query

  alias Decimal, as: D
  alias Liddr.Accounts.Driver
  alias Liddr.Accounts.User
  alias Liddr.Location.DriverLocation
  alias Liddr.Repo
  alias Liddr.Rides.CandidatePool
  alias Liddr.Rides.DispatchEta
  alias Liddr.Rides.DriverLiveness
  alias Liddr.Rides.DispatchPolicy
  alias Liddr.Rides.VehicleCategory

  @blocked_user_statuses ~w(suspended banned deactivated)

  def search_radius_km(%VehicleCategory{slug: slug}), do: radius_km_for(slug)
  def search_radius_km(slug) when is_binary(slug), do: radius_km_for(slug)

  def list_eligible_driver_ids(%VehicleCategory{} = category, pickup, limit, opts \\ []) do
    if not is_number(pickup.lat) or not is_number(pickup.lng) do
      []
    else
      do_list_eligible_driver_ids(category, pickup, limit, opts)
    end
  end

  defp do_list_eligible_driver_ids(%VehicleCategory{} = category, pickup, limit, opts) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    freshness_cutoff = DriverLiveness.dispatch_online_cutoff(now)
    radius_km = resolved_radius_km(category, opts)
    exclude_driver_ids = Keyword.get(opts, :exclude_driver_ids, [])
    {min_lat, max_lat, min_lng, max_lng} = bbox(pickup, radius_km)

    supply_prefilter =
      CandidatePool.prefilter_driver_ids(category, pickup, limit, radius_km, opts)
      |> maybe_exclude_from_prefilter(exclude_driver_ids)

    base_query =
      from d in Driver,
        join: u in User,
        on: u.id == d.user_id,
        join: dl in DriverLocation,
        on: dl.driver_id == d.user_id,
        where:
          d.vehicle_category_id == ^category.id and d.account_status == "active" and
            d.verification_status == "approved" and d.subscription_status == "active" and
            d.is_available == true and is_nil(d.current_ride_id) and d.dispatch_status == "idle" and
            dl.captured_at >= ^freshness_cutoff and dl.lat >= ^to_decimal(min_lat) and
            dl.lat <= ^to_decimal(max_lat) and dl.lng >= ^to_decimal(min_lng) and
            dl.lng <= ^to_decimal(max_lng) and
            (is_nil(u.account_status) or u.account_status not in ^@blocked_user_statuses),
        order_by: [desc: d.last_seen_at],
        select: %{
          driver_id: d.user_id,
          lat: dl.lat,
          lng: dl.lng,
          rating_score: u.rating_score,
          rating_count: u.rating_count
        }

    candidates =
      base_query
      |> maybe_apply_women_only_filter(category)
      |> maybe_apply_supply_prefilter(supply_prefilter)
      |> maybe_exclude_drivers(exclude_driver_ids, supply_prefilter)
      |> Repo.all()

    radius_m = radius_km * 1000.0

    candidates
    |> Enum.map(fn row ->
      distance_m =
        haversine_distance_m(
          pickup.lat,
          pickup.lng,
          decimal_to_float(row.lat),
          decimal_to_float(row.lng)
        )

      %{
        driver_id: row.driver_id,
        lat: decimal_to_float(row.lat),
        lng: decimal_to_float(row.lng),
        distance_m: distance_m,
        rating_score: effective_rating_score(row.rating_score, row.rating_count)
      }
    end)
    |> Enum.filter(&(&1.distance_m <= radius_m))
    |> DispatchEta.annotate(pickup, category.slug, now, limit, opts)
    |> rank_candidates()
    |> Enum.take(limit)
    |> Enum.map(& &1.driver_id)
  end

  defp radius_km_for("motorbike"), do: 3.5
  defp radius_km_for("electric_motorbike"), do: 4.0
  defp radius_km_for("send"), do: 4.0
  defp radius_km_for("basic"), do: 6.0
  defp radius_km_for("economy"), do: 6.0
  defp radius_km_for("women_only"), do: 6.0
  defp radius_km_for("green"), do: 6.0
  defp radius_km_for("comfort"), do: 7.0
  defp radius_km_for("xl"), do: 8.0
  defp radius_km_for(_slug), do: 6.0

  defp resolved_radius_km(%VehicleCategory{} = category, opts) do
    base_radius = radius_km_for(category.slug)
    radius_multiplier = Keyword.get(opts, :radius_multiplier, 1.0)
    custom_radius_km = Keyword.get(opts, :radius_km)

    cond do
      is_number(custom_radius_km) and custom_radius_km > 0 ->
        custom_radius_km * 1.0

      is_number(radius_multiplier) and radius_multiplier > 0 ->
        base_radius * (radius_multiplier * 1.0)

      true ->
        base_radius
    end
  end

  defp maybe_exclude_drivers(query, [], _prefilter_result), do: query

  defp maybe_exclude_drivers(query, driver_ids, {:ok, _prefiltered_ids}) when is_list(driver_ids),
    do: query

  defp maybe_exclude_drivers(query, driver_ids, _prefilter_result) when is_list(driver_ids) do
    from [d, _u, _dl] in query, where: d.user_id not in ^driver_ids
  end

  defp maybe_apply_supply_prefilter(query, {:ok, []}), do: query

  defp maybe_apply_supply_prefilter(query, {:ok, prefiltered_ids})
       when is_list(prefiltered_ids) do
    from [d, _u, _dl] in query, where: d.user_id in ^prefiltered_ids
  end

  defp maybe_apply_supply_prefilter(query, _prefilter_result), do: query

  defp maybe_apply_women_only_filter(query, %VehicleCategory{slug: "women_only"}) do
    from [d, u, _dl] in query, where: d.gender_verified == true and u.gender == "female"
  end

  defp maybe_apply_women_only_filter(query, _category), do: query

  defp maybe_exclude_from_prefilter({:ok, ids}, exclude_driver_ids)
       when is_list(exclude_driver_ids) do
    {:ok, Enum.reject(ids, &(&1 in exclude_driver_ids))}
  end

  defp maybe_exclude_from_prefilter(prefilter_result, _exclude_driver_ids), do: prefilter_result

  defp rank_candidates(candidates) do
    if Enum.any?(candidates, &(&1.eta_source == "google_routes")) do
      rank_with_google_eta(candidates)
    else
      rank_with_distance(candidates)
    end
  end

  defp rank_with_google_eta(candidates) do
    tiebreak_eta_s = DispatchPolicy.rating_tiebreak_eta_seconds()

    candidates
    |> Enum.map(fn candidate ->
      eta_seconds = resolve_eta_seconds(candidate)
      bucket = floor(eta_seconds / tiebreak_eta_s)
      eta_score = eta_score(eta_seconds)

      dispatch_score =
        DispatchPolicy.eta_weight() * eta_score +
          DispatchPolicy.rating_weight() * candidate.rating_score

      Map.merge(candidate, %{
        eta_seconds: eta_seconds,
        distance_bucket: bucket,
        eta_score: eta_score,
        dispatch_score: dispatch_score
      })
    end)
    |> Enum.sort_by(
      fn candidate ->
        {
          candidate.distance_bucket,
          -candidate.dispatch_score,
          candidate.eta_seconds,
          candidate.distance_m,
          -candidate.rating_score
        }
      end,
      :asc
    )
  end

  defp rank_with_distance(candidates) do
    tiebreak_distance_m = DispatchPolicy.rating_tiebreak_distance_m()

    candidates
    |> Enum.map(fn candidate ->
      bucket = floor(candidate.distance_m / tiebreak_distance_m)
      eta_score = eta_score_from_distance(candidate.distance_m)

      dispatch_score =
        DispatchPolicy.eta_weight() * eta_score +
          DispatchPolicy.rating_weight() * candidate.rating_score

      Map.merge(candidate, %{
        distance_bucket: bucket,
        eta_score: eta_score,
        dispatch_score: dispatch_score
      })
    end)
    |> Enum.sort_by(
      fn candidate ->
        {
          candidate.distance_bucket,
          -candidate.dispatch_score,
          candidate.distance_m,
          -candidate.rating_score
        }
      end,
      :asc
    )
  end

  defp eta_score(eta_seconds) do
    1.0 / (1.0 + eta_seconds / DispatchPolicy.eta_decay_seconds())
  end

  defp eta_score_from_distance(distance_m) do
    1.0 / (1.0 + distance_m / DispatchPolicy.eta_decay_m())
  end

  defp resolve_eta_seconds(%{eta_seconds: eta_seconds})
       when is_integer(eta_seconds) and eta_seconds > 0,
       do: eta_seconds

  defp resolve_eta_seconds(%{distance_m: distance_m}) when is_number(distance_m) do
    speed_mps = 28.0 * 1000.0 / 3600.0
    max(trunc(Float.ceil(distance_m / speed_mps)), 1)
  end

  defp resolve_eta_seconds(_candidate), do: 1

  defp effective_rating_score(raw_rating_score, raw_rating_count) do
    rating_count = parse_non_negative_integer(raw_rating_count, 0)

    if rating_count < DispatchPolicy.new_driver_min_rated_rides() do
      DispatchPolicy.new_driver_neutral_rating_score()
    else
      raw_rating_score
      |> decimal_to_float()
      |> normalize_rating()
    end
  end

  defp normalize_rating(score) when is_number(score) do
    clamped = min(max(score * 1.0, 1.0), 5.0)
    (clamped - 1.0) / 4.0
  end

  defp normalize_rating(_score), do: DispatchPolicy.new_driver_neutral_rating_score()

  defp parse_non_negative_integer(value, _default) when is_integer(value) and value >= 0,
    do: value

  defp parse_non_negative_integer(_value, default), do: default

  defp bbox(%{lat: lat, lng: lng}, radius_km) do
    lat_delta = radius_km / 111.0
    lng_delta = radius_km / (111.0 * max(:math.cos(lat * :math.pi() / 180.0), 0.1))
    {lat - lat_delta, lat + lat_delta, lng - lng_delta, lng + lng_delta}
  end

  defp haversine_distance_m(lat1, lon1, lat2, lon2) do
    rad = :math.pi() / 180.0
    d_lat = (lat2 - lat1) * rad
    d_lon = (lon2 - lon1) * rad

    a =
      :math.sin(d_lat / 2) * :math.sin(d_lat / 2) +
        :math.cos(lat1 * rad) * :math.cos(lat2 * rad) *
          :math.sin(d_lon / 2) * :math.sin(d_lon / 2)

    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
    6_371_000.0 * c
  end

  defp decimal_to_float(%D{} = value), do: D.to_float(value)
  defp decimal_to_float(value) when is_float(value), do: value
  defp decimal_to_float(value) when is_integer(value), do: value * 1.0
  defp decimal_to_float(_value), do: DispatchPolicy.new_driver_neutral_rating_score()

  defp to_decimal(value), do: D.from_float(value) |> D.round(7)
end
