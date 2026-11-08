defmodule LiddrWeb.RideGeofenceControllerTest do
  use LiddrWeb.ConnCase, async: false

  alias Liddr.Accounts.User
  alias Liddr.Repo
  alias Liddr.Rides.Ride
  alias Liddr.Rides.SharedRideGroup
  alias Liddr.Rides.SharedRideMember
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

  test "driver cannot mark arrived when too far from pickup", %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()

    _ =
      create_driver_profile!(driver_user_id, category_id,
        lat: Decimal.new("-1.3020000"),
        lng: Decimal.new("36.8290000")
      )

    %{"data" => %{"ride" => %{"id" => ride_id}, "offers" => [%{"id" => offer_id}]}} =
      request_ride!(rider_conn, category_id)

    _ = post(driver_conn, "/api/rides/offers/#{offer_id}/accept", %{}) |> json_response(200)

    assert %{"error" => %{"code" => "DRIVER_TOO_FAR_FROM_PICKUP"}} =
             post(driver_conn, "/api/rides/#{ride_id}/arrived", %{}) |> json_response(422)
  end

  test "driver cannot complete when too far from dropoff", %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    _ = create_driver_profile!(driver_user_id, category_id)

    %{"data" => %{"ride" => %{"id" => ride_id}, "offers" => [%{"id" => offer_id}]}} =
      request_ride!(rider_conn, category_id)

    _ = post(driver_conn, "/api/rides/offers/#{offer_id}/accept", %{}) |> json_response(200)
    _ = post(driver_conn, "/api/rides/#{ride_id}/arrived", %{}) |> json_response(200)
    _ = post(driver_conn, "/api/rides/#{ride_id}/start", %{}) |> json_response(200)

    assert %{"error" => %{"code" => "DRIVER_TOO_FAR_FROM_DROPOFF"}} =
             post(driver_conn, "/api/rides/#{ride_id}/complete", %{
               "payment_mode" => "mpesa_direct",
               "final_fare_kes" => "220.00"
             })
             |> json_response(422)
  end

  test "arrived and completed ride stores distance metrics when geofence passes", %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    _ = create_driver_profile!(driver_user_id, category_id)

    %{"data" => %{"ride" => %{"id" => ride_id}, "offers" => [%{"id" => offer_id}]}} =
      request_ride!(rider_conn, category_id)

    _ = post(driver_conn, "/api/rides/offers/#{offer_id}/accept", %{}) |> json_response(200)

    assert %{"data" => %{"ride" => %{"status" => "arrived", "arrival_distance_m" => arrival_m}}} =
             post(driver_conn, "/api/rides/#{ride_id}/arrived", %{}) |> json_response(200)

    assert is_integer(arrival_m)

    _ = post(driver_conn, "/api/rides/#{ride_id}/start", %{}) |> json_response(200)

    _ =
      post(driver_conn, "/api/drivers/me/location", %{
        "lat" => "-1.3000",
        "lng" => "36.8000"
      })
      |> json_response(200)

    assert %{
             "data" => %{
               "ride" => %{"status" => "completed", "completion_distance_m" => completion_m}
             }
           } =
             post(driver_conn, "/api/rides/#{ride_id}/complete", %{
               "payment_mode" => "mpesa_direct",
               "final_fare_kes" => "220.00"
             })
             |> json_response(200)

    assert is_integer(completion_m)
  end

  test "the final fare is the agreed fare whatever the driver sends", %{conn: conn} do
    for provided_fare <- [nil, "9999.00", "1.00", "NaN"] do
      %{driver_conn: driver_conn, ride_id: ride_id} = ride_at_dropoff!(conn, "200.00")

      assert complete_ride(driver_conn, ride_id, provided_fare) |> json_response(200)
      assert Decimal.equal?(Repo.get!(Ride, ride_id).final_fare_kes, Decimal.new("200.00"))
    end
  end

  test "a shared ride is completed at the total of its billed member fares", %{conn: conn} do
    %{driver_conn: driver_conn, ride_id: ride_id, ride: ride} = ride_at_dropoff!(conn, "200.00")
    ride = ride |> Ecto.Changeset.change(product_type: "shared") |> Repo.update!()
    insert_shared_members!(ride, ["150.00", "130.00"])

    assert complete_ride(driver_conn, ride_id, "9999.00") |> json_response(200)
    assert Decimal.equal?(Repo.get!(Ride, ride_id).final_fare_kes, Decimal.new("280.00"))
  end

  defp ride_at_dropoff!(conn, agreed_fare) do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    _ = create_driver_profile!(driver_user_id, category_id)

    %{"data" => %{"ride" => %{"id" => ride_id}, "offers" => [%{"id" => offer_id}]}} =
      request_ride!(rider_conn, category_id)

    _ = post(driver_conn, "/api/rides/offers/#{offer_id}/accept", %{}) |> json_response(200)
    _ = post(driver_conn, "/api/rides/#{ride_id}/arrived", %{}) |> json_response(200)
    _ = post(driver_conn, "/api/rides/#{ride_id}/start", %{}) |> json_response(200)

    _ =
      post(driver_conn, "/api/drivers/me/location", %{"lat" => "-1.3000", "lng" => "36.8000"})
      |> json_response(200)

    ride = Repo.get!(Ride, ride_id)
    metadata = Map.put(ride.metadata || %{}, "quoted_final_fare_kes", agreed_fare)
    ride = ride |> Ecto.Changeset.change(metadata: metadata) |> Repo.update!()

    %{driver_conn: driver_conn, ride_id: ride_id, ride: ride}
  end

  defp complete_ride(driver_conn, ride_id, final_fare) do
    params =
      %{"payment_mode" => "mpesa_direct"}
      |> then(&if(final_fare, do: Map.put(&1, "final_fare_kes", final_fare), else: &1))

    post(driver_conn, "/api/rides/#{ride_id}/complete", params)
  end

  defp insert_shared_members!(ride, fares) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    group =
      %SharedRideGroup{}
      |> SharedRideGroup.create_changeset(%{"ride_id" => ride.id, "max_members" => 2})
      |> Repo.insert!()

    for fare <- fares do
      rider = VerificationFixtures.create_user!()

      %SharedRideMember{}
      |> SharedRideMember.create_changeset(%{
        "group_id" => group.id,
        "ride_id" => ride.id,
        "rider_user_id" => rider.id,
        "status" => "picked_up",
        "requested_at" => now,
        "fare_kes" => Decimal.new(fare)
      })
      |> Repo.insert!()
    end
  end

  defp request_ride!(rider_conn, category_id) do
    rider_conn
    |> post_ride_request(%{
      "vehicle_category_id" => category_id,
      "pickup_lat" => "-1.2921",
      "pickup_lng" => "36.8219",
      "dropoff_lat" => "-1.3000",
      "dropoff_lng" => "36.8000",
      "offer_limit" => 1
    })
    |> json_response(201)
  end

  defp create_driver_profile!(user_id, category_id, opts \\ []) do
    user = Repo.get!(User, user_id)
    lat = Keyword.get(opts, :lat, Decimal.new("-1.2921000"))
    lng = Keyword.get(opts, :lng, Decimal.new("36.8219000"))

    driver =
      VerificationFixtures.create_driver!(
        user: user,
        vehicle_category_id: category_id,
        account_status: "active",
        verification_status: "approved",
        subscription_status: "active",
        is_available: true
      )

    _ = VerificationFixtures.create_driver_location!(driver.user_id, lat: lat, lng: lng)
    driver
  end
end
