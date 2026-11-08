defmodule LiddrWeb.RideDestinationChangeIdempotencyControllerTest do
  use LiddrWeb.ConnCase, async: false

  import Ecto.Query

  alias Decimal, as: D
  alias Liddr.Repo
  alias Liddr.Rides.RideDestinationChange
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

  defmodule FakeRoutesClient do
    @behaviour Liddr.Maps.RoutesClientBehaviour

    @impl true
    def compute_route(_input) do
      {:ok,
       %{
         distance_m: 2_900,
         duration_s: 760,
         static_duration_s: 700,
         polyline: "dest_change_idempotency_polyline",
         raw: %{"routes" => [%{}]}
       }}
    end
  end

  defmodule FakeMarketMultiplier do
    alias Decimal, as: D

    def build(_category, _pickup, _now) do
      {:ok,
       %{
         time_multiplier: D.new("1.00"),
         demand_multiplier: D.new("1.00"),
         market_multiplier: D.new("1.00"),
         demand_ratio: D.new("1.00"),
         available_driver_count: 8,
         active_request_count: 8
       }}
    end
  end

  setup do
    previous_client = Application.get_env(:liddr, :google_routes_client)
    previous_multiplier = Application.get_env(:liddr, :ride_market_multiplier)
    previous_policy = Application.get_env(:liddr, Liddr.Rides.DestinationChanges.Policy)

    Application.put_env(:liddr, :google_routes_client, FakeRoutesClient)
    Application.put_env(:liddr, :ride_market_multiplier, FakeMarketMultiplier)

    Application.put_env(:liddr, Liddr.Rides.DestinationChanges.Policy,
      cooldown_seconds: 0,
      max_elapsed_seconds: 7_200,
      request_ttl_seconds: 1_800,
      origin_location_freshness_seconds: 600
    )

    on_exit(fn ->
      restore_env(:google_routes_client, previous_client)
      restore_env(:ride_market_multiplier, previous_multiplier)

      if previous_policy do
        Application.put_env(:liddr, Liddr.Rides.DestinationChanges.Policy, previous_policy)
      else
        Application.delete_env(:liddr, Liddr.Rides.DestinationChanges.Policy)
      end
    end)

    :ok
  end

  test "destination change request replays for identical idempotency key", %{conn: conn} do
    %{rider_conn: rider_conn, ride_id: ride_id} = create_in_progress_ride!(conn)
    key = "dest-change-request-#{System.unique_integer([:positive])}"

    first =
      rider_conn
      |> put_req_header("idempotency-key", key)
      |> post("/api/rides/#{ride_id}/destination-change-requests", %{
        "new_dropoff_lat" => "-1.3151",
        "new_dropoff_lng" => "36.7902",
        "reason_code" => "other"
      })
      |> json_response(201)

    second =
      rider_conn
      |> recycle()
      |> put_req_header("idempotency-key", key)
      |> post("/api/rides/#{ride_id}/destination-change-requests", %{
        "new_dropoff_lat" => "-1.3151",
        "new_dropoff_lng" => "36.7902",
        "reason_code" => "other"
      })
      |> json_response(201)

    assert get_in(first, ["data", "destination_change", "id"]) ==
             get_in(second, ["data", "destination_change", "id"])

    count =
      Repo.one!(
        from dc in RideDestinationChange,
          where: dc.ride_id == ^ride_id,
          select: count(dc.id)
      )

    assert count == 1
  end

  test "destination change accept replays for identical idempotency key", %{conn: conn} do
    %{rider_conn: rider_conn, driver_conn: driver_conn, ride_id: ride_id} =
      create_in_progress_ride!(conn)

    change_id =
      rider_conn
      |> post("/api/rides/#{ride_id}/destination-change-requests", %{
        "new_dropoff_lat" => "-1.3200",
        "new_dropoff_lng" => "36.7850",
        "reason_code" => "other"
      })
      |> json_response(201)
      |> get_in(["data", "destination_change", "id"])

    key = "dest-change-accept-#{System.unique_integer([:positive])}"

    first =
      driver_conn
      |> put_req_header("idempotency-key", key)
      |> post("/api/rides/#{ride_id}/destination-change-requests/#{change_id}/accept", %{})
      |> json_response(200)

    second =
      driver_conn
      |> recycle()
      |> put_req_header("idempotency-key", key)
      |> post("/api/rides/#{ride_id}/destination-change-requests/#{change_id}/accept", %{})
      |> json_response(200)

    assert first == second
    assert get_in(first, ["data", "destination_change", "status"]) == "accepted"
  end

  defp restore_env(key, nil), do: Application.delete_env(:liddr, key)
  defp restore_env(key, value), do: Application.put_env(:liddr, key, value)

  defp create_in_progress_ride!(conn) do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!(%{slug: "basic"})

    _ = create_eligible_driver_profile!(driver_user_id, category_id)

    %{"data" => %{"ride" => %{"id" => ride_id}, "offers" => [%{"id" => offer_id}]}} =
      post_ride_request(rider_conn, %{
        "vehicle_category_id" => category_id,
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "offer_limit" => 1
      })
      |> json_response(201)

    _ = post(driver_conn, "/api/rides/offers/#{offer_id}/accept", %{}) |> json_response(200)
    _ = post(driver_conn, "/api/rides/#{ride_id}/arrived", %{}) |> json_response(200)
    _ = post(driver_conn, "/api/rides/#{ride_id}/start", %{}) |> json_response(200)

    %{rider_conn: rider_conn, driver_conn: driver_conn, ride_id: ride_id}
  end

  defp create_eligible_driver_profile!(user_id, category_id) do
    user = Repo.get!(Liddr.Accounts.User, user_id)

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
        lat: D.new("-1.2921000"),
        lng: D.new("36.8219000")
      )

    driver
  end
end
