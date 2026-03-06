defmodule Liddr.Rides.CandidateSelectionEtaTest do
  use Liddr.DataCase, async: false

  import Ecto.Query

  alias Decimal, as: D
  alias Liddr.Accounts.User
  alias Liddr.Repo
  alias Liddr.Rides.CandidateSelection
  alias Liddr.Rides.DispatchEta
  alias Liddr.Rides.VehicleCategory
  alias Liddr.VerificationFixtures

  defmodule FakeRoutesClient do
    @behaviour Liddr.Maps.RoutesClientBehaviour

    @impl true
    def compute_route(input) do
      origin_lat = read_point(input, :origin, :lat)

      cond do
        abs(origin_lat - -1.29220) < 0.00001 ->
          {:ok, %{distance_m: 2000, duration_s: 720, static_duration_s: 680, polyline: "near"}}

        abs(origin_lat - -1.29700) < 0.00001 ->
          {:ok, %{distance_m: 1600, duration_s: 180, static_duration_s: 160, polyline: "far"}}

        true ->
          {:ok, %{distance_m: 3000, duration_s: 300, static_duration_s: 260, polyline: "default"}}
      end
    end

    defp read_point(input, point_key, coord_key) do
      point = Map.get(input, point_key) || Map.get(input, Atom.to_string(point_key)) || %{}
      Map.get(point, coord_key) || Map.get(point, Atom.to_string(coord_key)) || 0.0
    end
  end

  defmodule FailingRoutesClient do
    @behaviour Liddr.Maps.RoutesClientBehaviour

    @impl true
    def compute_route(_input), do: {:error, :route_service_unavailable}
  end

  test "dispatch ranking uses road ETA when available" do
    previous_client = Application.get_env(:liddr, :google_routes_client)
    previous_eta = Application.get_env(:liddr, DispatchEta)

    on_exit(fn ->
      restore_env(:google_routes_client, previous_client)
      restore_env(DispatchEta, previous_eta)
    end)

    Application.put_env(:liddr, :google_routes_client, FakeRoutesClient)
    Application.put_env(:liddr, DispatchEta, eta_config(enabled: true))

    category_id = VerificationFixtures.insert_vehicle_category!()
    pickup = %{lat: -1.29210, lng: 36.82190}

    near_driver_id =
      create_eligible_driver!(category_id,
        lat: "-1.2922000",
        lng: "36.8219000",
        rating_score: "4.6",
        rating_count: 60
      )

    faster_road_eta_driver_id =
      create_eligible_driver!(category_id,
        lat: "-1.2970000",
        lng: "36.8219000",
        rating_score: "4.6",
        rating_count: 60
      )

    assert [first, second] =
             CandidateSelection.list_eligible_driver_ids(category(category_id), pickup, 2)

    assert first == faster_road_eta_driver_id
    assert second == near_driver_id
  end

  test "dispatch ranking falls back to haversine ETA when routes are unavailable" do
    previous_client = Application.get_env(:liddr, :google_routes_client)
    previous_eta = Application.get_env(:liddr, DispatchEta)

    on_exit(fn ->
      restore_env(:google_routes_client, previous_client)
      restore_env(DispatchEta, previous_eta)
    end)

    Application.put_env(:liddr, :google_routes_client, FailingRoutesClient)
    Application.put_env(:liddr, DispatchEta, eta_config(enabled: true))

    category_id = VerificationFixtures.insert_vehicle_category!()
    pickup = %{lat: -1.29210, lng: 36.82190}

    near_driver_id =
      create_eligible_driver!(category_id,
        lat: "-1.2922000",
        lng: "36.8219000",
        rating_score: "4.6",
        rating_count: 60
      )

    farther_driver_id =
      create_eligible_driver!(category_id,
        lat: "-1.2970000",
        lng: "36.8219000",
        rating_score: "4.6",
        rating_count: 60
      )

    assert [first, _second] =
             CandidateSelection.list_eligible_driver_ids(category(category_id), pickup, 2)

    assert first == near_driver_id
    refute first == farther_driver_id
  end

  defp eta_config(opts) do
    [
      enabled: Keyword.get(opts, :enabled, true),
      probe_limit: 8,
      max_concurrency: 2,
      timeout_ms: 200,
      fallback_speed_kph: 28.0,
      min_eta_seconds: 30,
      max_eta_seconds: 7_200
    ]
  end

  defp create_eligible_driver!(category_id, opts) do
    user = VerificationFixtures.create_user!()
    update_user_rating!(user.id, opts[:rating_score], opts[:rating_count] || 0)

    driver =
      VerificationFixtures.create_driver!(
        user: user,
        vehicle_category_id: category_id,
        account_status: "active",
        verification_status: "approved",
        subscription_status: "active",
        is_available: true
      )

    _ =
      VerificationFixtures.create_driver_location!(driver.user_id,
        lat: D.new(opts[:lat]),
        lng: D.new(opts[:lng])
      )

    driver.user_id
  end

  defp update_user_rating!(user_id, rating_score, rating_count) do
    _ =
      Repo.update_all(
        from(u in User, where: u.id == ^user_id),
        set: [rating_score: D.new(rating_score), rating_count: rating_count]
      )

    :ok
  end

  defp category(category_id), do: Repo.get!(VehicleCategory, category_id)

  defp restore_env(key, nil), do: Application.delete_env(:liddr, key)
  defp restore_env(key, value), do: Application.put_env(:liddr, key, value)
end
