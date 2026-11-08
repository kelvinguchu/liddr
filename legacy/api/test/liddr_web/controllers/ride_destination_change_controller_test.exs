defmodule LiddrWeb.RideDestinationChangeControllerTest do
  use LiddrWeb.ConnCase, async: false

  alias Decimal, as: D
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

  defmodule FakeRoutesClient do
    @behaviour Liddr.Maps.RoutesClientBehaviour

    @impl true
    def compute_route(input) do
      send(self(), {:destination_change_route_input, input})

      {:ok,
       %{
         distance_m: 3_120,
         duration_s: 780,
         static_duration_s: 710,
         polyline: "dest_change_polyline",
         raw: %{"routes" => [%{}]}
       }}
    end
  end

  defmodule FakeMarketMultiplier do
    alias Decimal, as: D

    def build(_category, _pickup, _now) do
      {:ok,
       %{
         time_multiplier: D.new("1.10"),
         demand_multiplier: D.new("1.05"),
         market_multiplier: D.new("1.15"),
         demand_ratio: D.new("1.20"),
         available_driver_count: 4,
         active_request_count: 6
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
      if previous_client do
        Application.put_env(:liddr, :google_routes_client, previous_client)
      else
        Application.delete_env(:liddr, :google_routes_client)
      end

      if previous_multiplier do
        Application.put_env(:liddr, :ride_market_multiplier, previous_multiplier)
      else
        Application.delete_env(:liddr, :ride_market_multiplier)
      end

      if previous_policy do
        Application.put_env(:liddr, Liddr.Rides.DestinationChanges.Policy, previous_policy)
      else
        Application.delete_env(:liddr, Liddr.Rides.DestinationChanges.Policy)
      end
    end)

    :ok
  end

  test "rider requests destination change and driver accepts", %{conn: conn} do
    %{rider_conn: rider_conn, driver_conn: driver_conn, ride_id: ride_id} =
      create_in_progress_ride!(conn)

    request_conn =
      post(rider_conn, "/api/rides/#{ride_id}/destination-change-requests", %{
        "new_dropoff_lat" => "-1.3151",
        "new_dropoff_lng" => "36.7902",
        "reason_code" => "wrong_dropoff_selected",
        "notes" => "Updated destination"
      })

    assert %{
             "data" => %{
               "ride" => %{"id" => ^ride_id, "status" => "in_progress"},
               "destination_change" => %{
                 "id" => change_id,
                 "status" => "requested",
                 "reason_code" => "wrong_dropoff_selected",
                 "new_fare_kes" => new_fare_kes,
                 "old_fare_kes" => old_fare_kes
               }
             }
           } = json_response(request_conn, 201)

    assert_received {:destination_change_route_input, %{travel_mode: "DRIVE"}}
    assert D.compare(D.new(new_fare_kes), D.new(old_fare_kes)) in [:gt, :eq, :lt]

    accept_conn =
      post(
        driver_conn,
        "/api/rides/#{ride_id}/destination-change-requests/#{change_id}/accept",
        %{}
      )

    assert %{
             "data" => %{
               "ride" => %{
                 "id" => ^ride_id,
                 "dropoff_lat" => "-1.3151000",
                 "dropoff_lng" => "36.7902000"
               },
               "destination_change" => %{
                 "id" => ^change_id,
                 "status" => "accepted"
               }
             }
           } = json_response(accept_conn, 200)

    events_conn = get(rider_conn, "/api/rides/#{ride_id}/events")
    assert %{"data" => %{"events" => events}} = json_response(events_conn, 200)

    assert Enum.any?(events, fn event ->
             event["event_type"] == "destination_change_requested"
           end)

    assert Enum.any?(events, fn event ->
             event["event_type"] == "destination_change_accepted"
           end)
  end

  test "shared rides reject destination change requests", %{conn: conn} do
    %{rider_conn: rider_conn, ride_id: ride_id} =
      create_in_progress_ride!(conn, product_type: "shared")

    response =
      post(rider_conn, "/api/rides/#{ride_id}/destination-change-requests", %{
        "new_dropoff_lat" => "-1.3201",
        "new_dropoff_lng" => "36.8101",
        "reason_code" => "rider_changed_plan"
      })

    assert %{"error" => %{"code" => "RIDE_DESTINATION_CHANGE_SHARED_NOT_ALLOWED"}} =
             json_response(response, 422)
  end

  test "ride enforces max two destination changes", %{conn: conn} do
    %{rider_conn: rider_conn, driver_conn: driver_conn, ride_id: ride_id} =
      create_in_progress_ride!(conn)

    first_change_id = request_destination_change!(rider_conn, ride_id, "-1.3151", "36.7902")
    _ = reject_destination_change!(driver_conn, ride_id, first_change_id)

    second_change_id = request_destination_change!(rider_conn, ride_id, "-1.3200", "36.7850")
    _ = reject_destination_change!(driver_conn, ride_id, second_change_id)

    third_request =
      post(rider_conn, "/api/rides/#{ride_id}/destination-change-requests", %{
        "new_dropoff_lat" => "-1.3180",
        "new_dropoff_lng" => "36.7880",
        "reason_code" => "other"
      })

    assert %{"error" => %{"code" => "DESTINATION_CHANGE_LIMIT_REACHED"}} =
             json_response(third_request, 422)
  end

  defp request_destination_change!(rider_conn, ride_id, lat, lng) do
    response =
      post(rider_conn, "/api/rides/#{ride_id}/destination-change-requests", %{
        "new_dropoff_lat" => lat,
        "new_dropoff_lng" => lng,
        "reason_code" => "other"
      })
      |> json_response(201)

    get_in(response, ["data", "destination_change", "id"])
  end

  defp reject_destination_change!(driver_conn, ride_id, change_id) do
    post(
      driver_conn,
      "/api/rides/#{ride_id}/destination-change-requests/#{change_id}/reject",
      %{"reason_code" => "driver_declined"}
    )
    |> json_response(200)
  end

  defp create_in_progress_ride!(conn, opts \\ []) do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!(%{slug: "basic"})

    _ = create_eligible_driver_profile!(driver_user_id, category_id)

    request_body = %{
      "vehicle_category_id" => category_id,
      "pickup_lat" => "-1.2921",
      "pickup_lng" => "36.8219",
      "dropoff_lat" => "-1.3000",
      "dropoff_lng" => "36.8000",
      "offer_limit" => 1
    }

    request_body =
      case Keyword.get(opts, :product_type) do
        nil -> request_body
        product_type -> Map.put(request_body, "product_type", product_type)
      end

    %{"data" => %{"ride" => %{"id" => ride_id}, "offers" => [%{"id" => offer_id}]}} =
      post(rider_conn, "/api/rides/requests", request_body) |> json_response(201)

    _ = post(driver_conn, "/api/rides/offers/#{offer_id}/accept", %{}) |> json_response(200)
    _ = post(driver_conn, "/api/rides/#{ride_id}/arrived", %{}) |> json_response(200)
    _ = post(driver_conn, "/api/rides/#{ride_id}/start", %{}) |> json_response(200)

    %{rider_conn: rider_conn, driver_conn: driver_conn, ride_id: ride_id}
  end

  defp create_eligible_driver_profile!(user_id, category_id) do
    user = Liddr.Repo.get!(Liddr.Accounts.User, user_id)

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
