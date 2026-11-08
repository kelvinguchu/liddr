defmodule LiddrWeb.RideDestinationChangePolicyTest do
  use LiddrWeb.ConnCase, async: false

  import Ecto.Query

  alias Decimal, as: D
  alias Liddr.Location.DriverLocation
  alias Liddr.Repo
  alias Liddr.Rides.Ride
  alias Liddr.Rides.RideDestinationChange
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

  @policy_module Liddr.Rides.DestinationChanges.Policy

  setup do
    previous_client = Application.get_env(:liddr, :google_routes_client)
    previous_multiplier = Application.get_env(:liddr, :ride_market_multiplier)

    Application.put_env(
      :liddr,
      :google_routes_client,
      LiddrWeb.RideDestinationChangeControllerTest.FakeRoutesClient
    )

    Application.put_env(
      :liddr,
      :ride_market_multiplier,
      LiddrWeb.RideDestinationChangeControllerTest.FakeMarketMultiplier
    )

    on_exit(fn ->
      restore_env(:google_routes_client, previous_client)
      restore_env(:ride_market_multiplier, previous_multiplier)
    end)

    :ok
  end

  test "enforces cooldown between destination change requests", %{conn: conn} do
    with_policy(
      [
        cooldown_seconds: 300,
        max_elapsed_seconds: 7_200,
        request_ttl_seconds: 1_800,
        origin_location_freshness_seconds: 600
      ],
      fn ->
        %{rider_conn: rider_conn, driver_conn: driver_conn, ride_id: ride_id} =
          create_in_progress_ride!(conn)

        change_id = request_destination_change!(rider_conn, ride_id, "-1.3151", "36.7902")
        _ = reject_destination_change!(driver_conn, ride_id, change_id)

        second_request =
          post(rider_conn, "/api/rides/#{ride_id}/destination-change-requests", %{
            "new_dropoff_lat" => "-1.3200",
            "new_dropoff_lng" => "36.7850",
            "reason_code" => "other"
          })

        assert %{"error" => %{"code" => "DESTINATION_CHANGE_COOLDOWN_ACTIVE"}} =
                 json_response(second_request, 429)
      end
    )
  end

  test "rejects stale pending destination change acceptance", %{conn: conn} do
    with_policy(
      [
        cooldown_seconds: 0,
        max_elapsed_seconds: 7_200,
        request_ttl_seconds: 30,
        origin_location_freshness_seconds: 600
      ],
      fn ->
        %{rider_conn: rider_conn, driver_conn: driver_conn, ride_id: ride_id} =
          create_in_progress_ride!(conn)

        change_id = request_destination_change!(rider_conn, ride_id, "-1.3151", "36.7902")

        stale_requested_at =
          DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:microsecond)

        from(dc in RideDestinationChange, where: dc.id == ^change_id)
        |> Repo.update_all(set: [requested_at: stale_requested_at])

        response =
          post(
            driver_conn,
            "/api/rides/#{ride_id}/destination-change-requests/#{change_id}/accept",
            %{}
          )

        assert %{"error" => %{"code" => "DESTINATION_CHANGE_REQUEST_STALE"}} =
                 json_response(response, 409)
      end
    )
  end

  test "rejects destination change after trip window elapsed", %{conn: conn} do
    with_policy(
      [
        cooldown_seconds: 0,
        max_elapsed_seconds: 60,
        request_ttl_seconds: 1_800,
        origin_location_freshness_seconds: 600
      ],
      fn ->
        %{rider_conn: rider_conn, ride_id: ride_id} = create_in_progress_ride!(conn)

        stale_started_at =
          DateTime.utc_now() |> DateTime.add(-300, :second) |> DateTime.truncate(:microsecond)

        from(r in Ride, where: r.id == ^ride_id)
        |> Repo.update_all(set: [started_at: stale_started_at])

        response =
          post(rider_conn, "/api/rides/#{ride_id}/destination-change-requests", %{
            "new_dropoff_lat" => "-1.3201",
            "new_dropoff_lng" => "36.8101",
            "reason_code" => "rider_changed_plan"
          })

        assert %{"error" => %{"code" => "DESTINATION_CHANGE_WINDOW_ELAPSED"}} =
                 json_response(response, 422)
      end
    )
  end

  test "rejects destination change when driver location is stale", %{conn: conn} do
    with_policy(
      [
        cooldown_seconds: 0,
        max_elapsed_seconds: 7_200,
        request_ttl_seconds: 1_800,
        origin_location_freshness_seconds: 30
      ],
      fn ->
        %{rider_conn: rider_conn, ride_id: ride_id} = create_in_progress_ride!(conn)
        ride = Repo.get!(Ride, ride_id)

        stale_captured_at =
          DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:microsecond)

        from(dl in DriverLocation, where: dl.driver_id == ^ride.driver_id)
        |> Repo.update_all(set: [captured_at: stale_captured_at])

        response =
          post(rider_conn, "/api/rides/#{ride_id}/destination-change-requests", %{
            "new_dropoff_lat" => "-1.3201",
            "new_dropoff_lng" => "36.8101",
            "reason_code" => "other"
          })

        assert %{"error" => %{"code" => "DESTINATION_CHANGE_ORIGIN_STALE"}} =
                 json_response(response, 409)
      end
    )
  end

  defp with_policy(policy, fun) do
    previous_policy = Application.get_env(:liddr, @policy_module)
    Application.put_env(:liddr, @policy_module, policy)

    try do
      fun.()
    after
      restore_env(@policy_module, previous_policy)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:liddr, key)
  defp restore_env(key, value), do: Application.put_env(:liddr, key, value)

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

  defp create_in_progress_ride!(conn) do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!(%{slug: "basic"})

    _ = create_eligible_driver_profile!(driver_user_id, category_id)

    %{"data" => %{"ride" => %{"id" => ride_id}, "offers" => [%{"id" => offer_id}]}} =
      post(rider_conn, "/api/rides/requests", %{
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
