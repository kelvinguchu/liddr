defmodule LiddrWeb.RideDispatchFlowTest do
  use LiddrWeb.ConnCase, async: false

  import Ecto.Query

  alias Liddr.Accounts.User
  alias Liddr.Repo
  alias Liddr.Rides.Dispatcher
  alias Liddr.Rides.RideEvent
  alias Liddr.Rides.RideOffer
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

  test "dispatch sends offers only to nearby eligible drivers", %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{user_id: near_driver_id} = AuthFixtures.authenticate_driver!(conn)
    %{user_id: far_driver_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()

    near_user = Repo.get!(User, near_driver_id)
    far_user = Repo.get!(User, far_driver_id)

    near_driver =
      VerificationFixtures.create_driver!(
        user: near_user,
        vehicle_category_id: category_id,
        account_status: "active",
        verification_status: "approved",
        subscription_status: "active",
        is_available: true
      )

    far_driver =
      VerificationFixtures.create_driver!(
        user: far_user,
        vehicle_category_id: category_id,
        account_status: "active",
        verification_status: "approved",
        subscription_status: "active",
        is_available: true
      )

    _ =
      VerificationFixtures.create_driver_location!(near_driver.user_id,
        lat: Decimal.new("-1.2921000"),
        lng: Decimal.new("36.8219000")
      )

    _ =
      VerificationFixtures.create_driver_location!(far_driver.user_id,
        lat: Decimal.new("-1.5500000"),
        lng: Decimal.new("36.8000000")
      )

    conn =
      post(rider_conn, "/api/rides/requests", %{
        "vehicle_category_id" => category_id,
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "offer_limit" => 5,
        "offer_ttl_seconds" => 60
      })

    assert %{"data" => %{"offers" => offers}} = json_response(conn, 201)
    offered_driver_ids = Enum.map(offers, & &1["driver_id"])
    assert near_driver_id in offered_driver_ids
    refute far_driver_id in offered_driver_ids
  end

  test "driver becomes busy after accept and unlocks after completion", %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    driver_user = Repo.get!(User, driver_user_id)

    driver =
      VerificationFixtures.create_driver!(
        user: driver_user,
        vehicle_category_id: category_id,
        account_status: "active",
        verification_status: "approved",
        subscription_status: "active",
        is_available: true
      )

    _ =
      VerificationFixtures.create_driver_location!(driver.user_id,
        lat: Decimal.new("-1.2921000"),
        lng: Decimal.new("36.8219000")
      )

    first_request =
      post(rider_conn, "/api/rides/requests", %{
        "vehicle_category_id" => category_id,
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "offer_limit" => 1,
        "offer_ttl_seconds" => 60
      })

    assert %{
             "data" => %{
               "ride" => %{"id" => ride_id},
               "offers" => [%{"id" => offer_id}]
             }
           } = json_response(first_request, 201)

    accepted = post(driver_conn, "/api/rides/offers/#{offer_id}/accept", %{})
    assert %{"data" => %{"ride" => %{"status" => "accepted"}}} = json_response(accepted, 200)

    arriving = post(driver_conn, "/api/rides/#{ride_id}/driver-arriving", %{})

    assert %{"data" => %{"ride" => %{"status" => "driver_arriving"}}} =
             json_response(arriving, 200)

    arrived = post(driver_conn, "/api/rides/#{ride_id}/arrived", %{})
    assert %{"data" => %{"ride" => %{"status" => "arrived"}}} = json_response(arrived, 200)

    started = post(driver_conn, "/api/rides/#{ride_id}/start", %{})
    assert %{"data" => %{"ride" => %{"status" => "in_progress"}}} = json_response(started, 200)

    _ =
      post(driver_conn, "/api/drivers/me/location", %{
        "lat" => "-1.3000",
        "lng" => "36.8000"
      })
      |> json_response(200)

    second_request =
      post(rider_conn, "/api/rides/requests", %{
        "vehicle_category_id" => category_id,
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "offer_limit" => 1,
        "offer_ttl_seconds" => 60
      })

    assert %{"data" => %{"offers_count" => 0}} = json_response(second_request, 201)

    completed =
      post(driver_conn, "/api/rides/#{ride_id}/complete", %{
        "payment_mode" => "mpesa_direct",
        "final_fare_kes" => "220.00"
      })

    assert %{"data" => %{"ride" => %{"status" => "completed"}}} = json_response(completed, 200)

    third_request =
      post(rider_conn, "/api/rides/requests", %{
        "vehicle_category_id" => category_id,
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "offer_limit" => 1,
        "offer_ttl_seconds" => 60
      })

    assert %{"data" => %{"offers_count" => 1}} = json_response(third_request, 201)
  end

  test "dispatch expands to next eligible driver after first offer expires", %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{user_id: first_driver_id} = AuthFixtures.authenticate_driver!(conn)
    %{user_id: second_driver_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()

    first_user = Repo.get!(User, first_driver_id)
    second_user = Repo.get!(User, second_driver_id)

    first_driver =
      VerificationFixtures.create_driver!(
        user: first_user,
        vehicle_category_id: category_id,
        account_status: "active",
        verification_status: "approved",
        subscription_status: "active",
        is_available: true
      )

    second_driver =
      VerificationFixtures.create_driver!(
        user: second_user,
        vehicle_category_id: category_id,
        account_status: "active",
        verification_status: "approved",
        subscription_status: "active",
        is_available: true
      )

    _ =
      VerificationFixtures.create_driver_location!(first_driver.user_id,
        lat: Decimal.new("-1.2921000"),
        lng: Decimal.new("36.8219000")
      )

    _ =
      VerificationFixtures.create_driver_location!(second_driver.user_id,
        lat: Decimal.new("-1.2929000"),
        lng: Decimal.new("36.8226000")
      )

    request_conn =
      post(rider_conn, "/api/rides/requests", %{
        "vehicle_category_id" => category_id,
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "offer_limit" => 1,
        "offer_ttl_seconds" => 30
      })

    assert %{
             "data" => %{
               "ride" => %{"id" => ride_id},
               "offers" => [%{"driver_id" => offered_driver_id}]
             }
           } = json_response(request_conn, 201)

    assert offered_driver_id == first_driver_id

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    _ =
      Repo.update_all(
        from(o in RideOffer, where: o.ride_id == ^ride_id and o.driver_id == ^first_driver_id),
        set: [
          offered_at: DateTime.add(now, -90, :second),
          expires_at: DateTime.add(now, -60, :second),
          updated_at: now
        ]
      )

    assert {:ok, _pid} =
             Dispatcher.ensure_started(ride_id, offer_limit: 1, offer_ttl_seconds: 30)

    on_exit(fn -> Dispatcher.stop(ride_id) end)

    assert :ok = Dispatcher.dispatch_now(ride_id)

    statuses =
      Repo.all(
        from o in RideOffer,
          where: o.ride_id == ^ride_id,
          select: {o.driver_id, o.status}
      )

    assert {first_driver_id, "expired"} in statuses
    assert {second_driver_id, "offered"} in statuses

    dispatch_events =
      Repo.all(
        from e in RideEvent,
          where: e.ride_id == ^ride_id and e.event_type in ["offer_expired", "offer_created"],
          select: {e.event_type, e.payload}
      )

    assert Enum.any?(dispatch_events, fn
             {"offer_expired", %{"driver_id" => ^first_driver_id}} -> true
             _ -> false
           end)

    assert Enum.any?(dispatch_events, fn
             {"offer_created", %{"driver_id" => ^second_driver_id}} -> true
             _ -> false
           end)
  end
end
