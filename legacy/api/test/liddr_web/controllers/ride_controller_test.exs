defmodule LiddrWeb.RideControllerTest do
  use LiddrWeb.ConnCase, async: false

  import Ecto.Query

  alias Liddr.Accounts.Driver
  alias Liddr.Accounts.User
  alias Liddr.Repo
  alias Liddr.Rides.Ride
  alias Liddr.Rides.RideOffer
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

  test "POST /api/rides/requests requires rider role", %{conn: conn} do
    %{auth_conn: auth_conn} = AuthFixtures.authenticate_driver!(conn)

    conn =
      post(auth_conn, "/api/rides/requests", %{
        "vehicle_category_id" => 1,
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000"
      })

    assert %{"error" => %{"code" => "FORBIDDEN_ROLE"}} = json_response(conn, 403)
  end

  test "POST /api/rides/requests blocks banned rider account", %{conn: conn} do
    %{auth_conn: rider_conn, user_id: rider_user_id} = AuthFixtures.authenticate_rider!(conn)

    {1, _} =
      Repo.update_all(
        from(u in User, where: u.id == ^rider_user_id),
        set: [account_status: "banned", account_status_reason_code: "policy_violation"]
      )

    conn =
      post(rider_conn, "/api/rides/requests", %{
        "vehicle_category_id" => 1,
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000"
      })

    assert %{"error" => %{"code" => "ACCOUNT_BANNED"}} = json_response(conn, 403)
  end

  test "POST /api/rides/requests blocks shared product_type for two-wheel categories", %{
    conn: conn
  } do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    motorbike_id = VerificationFixtures.insert_vehicle_category!(%{slug: "motorbike"})

    conn =
      post(rider_conn, "/api/rides/requests", %{
        "vehicle_category_id" => motorbike_id,
        "product_type" => "shared",
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000"
      })

    assert %{"error" => %{"code" => "SHARED_NOT_SUPPORTED_FOR_CATEGORY"}} =
             json_response(conn, 422)
  end

  test "POST /api/rides/requests creates offers for eligible drivers and GET /api/rides/offers lists them",
       %{
         conn: conn
       } do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()

    _ =
      create_eligible_driver_profile!(driver_user_id, category_id)

    second_driver =
      VerificationFixtures.create_driver!(
        vehicle_category_id: category_id,
        account_status: "active",
        verification_status: "approved",
        subscription_status: "active",
        is_available: true
      )

    _ =
      VerificationFixtures.create_driver_location!(second_driver.user_id,
        lat: Decimal.new("-1.2922000"),
        lng: Decimal.new("36.8220000")
      )

    request_conn =
      post(rider_conn, "/api/rides/requests", %{
        "vehicle_category_id" => category_id,
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "offer_limit" => 2,
        "offer_ttl_seconds" => 30
      })

    assert %{
             "data" => %{
               "ride" => %{"id" => ride_id, "status" => "offering"},
               "offers_count" => 2,
               "offers" => [first_offer | _]
             }
           } = json_response(request_conn, 201)

    assert first_offer["response_state"] == "pending_response"
    assert is_integer(first_offer["response_window_seconds"])
    assert is_integer(first_offer["response_window_remaining_seconds"])

    offers_conn = get(driver_conn, "/api/rides/offers")

    assert %{"data" => %{"offers" => offers}} = json_response(offers_conn, 200)
    assert Enum.any?(offers, fn row -> row["ride"]["id"] == ride_id end)
  end

  test "POST /api/rides/offers/:offer_id/accept enforces subscription_status == active", %{
    conn: conn
  } do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()

    _ = create_eligible_driver_profile!(driver_user_id, category_id)

    request_conn =
      post(rider_conn, "/api/rides/requests", %{
        "vehicle_category_id" => category_id,
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "offer_limit" => 1
      })

    assert %{
             "data" => %{
               "offers" => [%{"driver_id" => ^driver_user_id, "id" => offer_id}]
             }
           } = json_response(request_conn, 201)

    {1, _} =
      Repo.update_all(
        from(d in Driver, where: d.user_id == ^driver_user_id),
        set: [subscription_status: "inactive"]
      )

    accept_conn = post(driver_conn, "/api/rides/offers/#{offer_id}/accept", %{})

    assert %{"error" => %{"code" => "DRIVER_SUBSCRIPTION_NOT_ACTIVE"}} =
             json_response(accept_conn, 403)
  end

  test "POST /api/rides/offers/:offer_id/accept enforces driver availability", %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()

    _ = create_eligible_driver_profile!(driver_user_id, category_id)

    request_conn =
      post(rider_conn, "/api/rides/requests", %{
        "vehicle_category_id" => category_id,
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "offer_limit" => 1
      })

    assert %{
             "data" => %{
               "offers" => [%{"driver_id" => ^driver_user_id, "id" => offer_id}]
             }
           } = json_response(request_conn, 201)

    {1, _} =
      Repo.update_all(
        from(d in Driver, where: d.user_id == ^driver_user_id),
        set: [is_available: false]
      )

    accept_conn = post(driver_conn, "/api/rides/offers/#{offer_id}/accept", %{})
    assert %{"error" => %{"code" => "DRIVER_NOT_AVAILABLE"}} = json_response(accept_conn, 403)
  end

  test "POST /api/rides/offers/:offer_id/accept assigns ride and withdraws competing offers", %{
    conn: conn
  } do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()

    _ = create_eligible_driver_profile!(driver_user_id, category_id)

    competing_user = VerificationFixtures.create_user!()

    competing_driver =
      VerificationFixtures.create_driver!(
        user: competing_user,
        vehicle_category_id: category_id,
        account_status: "active",
        verification_status: "approved",
        subscription_status: "active",
        is_available: true
      )

    _ =
      VerificationFixtures.create_driver_location!(competing_driver.user_id,
        lat: Decimal.new("-1.2922000"),
        lng: Decimal.new("36.8220000")
      )

    request_conn =
      post(rider_conn, "/api/rides/requests", %{
        "vehicle_category_id" => category_id,
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "offer_limit" => 2
      })

    assert %{
             "data" => %{
               "ride" => %{"id" => ride_id},
               "offers" => offers
             }
           } = json_response(request_conn, 201)

    selected_offer = Enum.find(offers, fn offer -> offer["driver_id"] == driver_user_id end)
    accept_conn = post(driver_conn, "/api/rides/offers/#{selected_offer["id"]}/accept", %{})

    assert %{
             "data" => %{
               "ride" => %{
                 "id" => ^ride_id,
                 "driver_id" => ^driver_user_id,
                 "status" => "accepted"
               },
               "offer" => %{"status" => "accepted"}
             }
           } = json_response(accept_conn, 200)

    persisted_ride = Repo.get!(Ride, ride_id)
    assert persisted_ride.driver_id == driver_user_id
    assert persisted_ride.status == "accepted"

    statuses =
      Repo.all(
        from o in RideOffer,
          where: o.ride_id == ^ride_id,
          select: {o.driver_id, o.status}
      )

    assert Enum.any?(statuses, fn {id, status} ->
             id == driver_user_id and status == "accepted"
           end)

    assert Enum.any?(statuses, fn {id, status} ->
             id != driver_user_id and status == "withdrawn"
           end)
  end

  test "POST /api/rides/offers/:offer_id/accept rejects stale withdrawn offers", %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)

    %{auth_conn: first_driver_conn, user_id: first_driver_user_id} =
      AuthFixtures.authenticate_driver!(conn)

    %{auth_conn: second_driver_conn, user_id: second_driver_user_id} =
      AuthFixtures.authenticate_driver!(conn)

    category_id = VerificationFixtures.insert_vehicle_category!()

    _ = create_eligible_driver_profile!(first_driver_user_id, category_id)
    _ = create_eligible_driver_profile!(second_driver_user_id, category_id)

    request_conn =
      post(rider_conn, "/api/rides/requests", %{
        "vehicle_category_id" => category_id,
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "offer_limit" => 2,
        "offer_ttl_seconds" => 30
      })

    assert %{"data" => %{"offers" => offers}} = json_response(request_conn, 201)

    first_offer_id =
      offers
      |> Enum.find(&(&1["driver_id"] == first_driver_user_id))
      |> Map.fetch!("id")

    stale_offer_id =
      offers
      |> Enum.find(&(&1["driver_id"] == second_driver_user_id))
      |> Map.fetch!("id")

    assert %{"data" => %{"ride" => %{"status" => "accepted"}}} =
             post(first_driver_conn, "/api/rides/offers/#{first_offer_id}/accept", %{})
             |> json_response(200)

    assert %{"error" => %{"code" => "RIDE_OFFER_NOT_OPEN"}} =
             post(second_driver_conn, "/api/rides/offers/#{stale_offer_id}/accept", %{})
             |> json_response(422)
  end

  test "POST /api/rides/offers/:offer_id/accept blocks accepting a second active ride", %{
    conn: conn
  } do
    %{auth_conn: first_rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{user_id: second_rider_user_id} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()

    _ = create_eligible_driver_profile!(driver_user_id, category_id)

    first_request_conn =
      post(first_rider_conn, "/api/rides/requests", %{
        "vehicle_category_id" => category_id,
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "offer_limit" => 1,
        "offer_ttl_seconds" => 30
      })

    assert %{"data" => %{"offers" => [%{"id" => first_offer_id}]}} =
             json_response(first_request_conn, 201)

    assert %{"data" => %{"ride" => %{"status" => "accepted"}}} =
             post(driver_conn, "/api/rides/offers/#{first_offer_id}/accept", %{})
             |> json_response(200)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    second_ride =
      %Ride{}
      |> Ride.create_changeset(%{
        "rider_id" => second_rider_user_id,
        "vehicle_category_id" => category_id,
        "status" => "offering",
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "requested_at" => now
      })
      |> Repo.insert!()

    second_offer =
      %RideOffer{}
      |> RideOffer.create_changeset(%{
        "ride_id" => second_ride.id,
        "driver_id" => driver_user_id,
        "status" => "offered",
        "offered_at" => now,
        "expires_at" => DateTime.add(now, 45, :second)
      })
      |> Repo.insert!()

    assert %{"error" => %{"code" => "DRIVER_HAS_ACTIVE_RIDE"}} =
             post(driver_conn, "/api/rides/offers/#{second_offer.id}/accept", %{})
             |> json_response(403)

    reloaded_offer = Repo.get!(RideOffer, second_offer.id)
    assert reloaded_offer.status == "offered"

    reloaded_first_ride = Repo.get!(Ride, second_ride.id)
    assert reloaded_first_ride.driver_id == nil
    assert reloaded_first_ride.status == "offering"
  end

  test "GET rider and driver ride history endpoints return accepted ride records", %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()

    _ = create_eligible_driver_profile!(driver_user_id, category_id)

    request_conn =
      post(rider_conn, "/api/rides/requests", %{
        "vehicle_category_id" => category_id,
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "offer_limit" => 1
      })

    assert %{
             "data" => %{
               "offers" => [%{"id" => offer_id}]
             }
           } = json_response(request_conn, 201)

    _ = post(driver_conn, "/api/rides/offers/#{offer_id}/accept", %{})

    rider_history_conn = get(rider_conn, "/api/rides/history/rider")
    driver_history_conn = get(driver_conn, "/api/rides/history/driver")

    assert %{"data" => %{"rides" => [first | _]}} = json_response(rider_history_conn, 200)
    assert first["status"] == "accepted"
    assert first["driver_id"] == driver_user_id

    assert %{"data" => %{"rides" => [driver_first | _]}} = json_response(driver_history_conn, 200)
    assert driver_first["status"] == "accepted"
    assert driver_first["driver_id"] == driver_user_id
  end

  test "concurrent accept attempts only assign one driver", %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{user_id: first_driver_id} = AuthFixtures.authenticate_driver!(conn)
    %{user_id: second_driver_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()

    _ = create_eligible_driver_profile!(first_driver_id, category_id)
    _ = create_eligible_driver_profile!(second_driver_id, category_id)

    request_conn =
      post(rider_conn, "/api/rides/requests", %{
        "vehicle_category_id" => category_id,
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "offer_limit" => 2,
        "offer_ttl_seconds" => 30
      })

    assert %{
             "data" => %{
               "ride" => %{"id" => ride_id},
               "offers" => offers
             }
           } = json_response(request_conn, 201)

    first_offer_id =
      offers
      |> Enum.find(&(&1["driver_id"] == first_driver_id))
      |> Map.fetch!("id")

    second_offer_id =
      offers
      |> Enum.find(&(&1["driver_id"] == second_driver_id))
      |> Map.fetch!("id")

    first_task =
      Task.async(fn ->
        Liddr.Rides.accept_offer(first_driver_id, first_offer_id)
      end)

    second_task =
      Task.async(fn ->
        Liddr.Rides.accept_offer(second_driver_id, second_offer_id)
      end)

    results = [Task.await(first_task, 5_000), Task.await(second_task, 5_000)]

    success_count = Enum.count(results, &match?({:ok, _}, &1))
    assert success_count == 1

    assert Enum.any?(results, fn
             {:error, :ride_not_assignable} -> true
             {:error, :ride_offer_not_open} -> true
             _ -> false
           end)

    ride = Repo.get!(Ride, ride_id)
    assert ride.driver_id in [first_driver_id, second_driver_id]
    assert ride.status == "accepted"

    accepted_count =
      Repo.aggregate(
        from(o in RideOffer, where: o.ride_id == ^ride_id and o.status == "accepted"),
        :count,
        :id
      )

    assert accepted_count == 1
  end

  defp create_eligible_driver_profile!(user_id, category_id) do
    user = Repo.get!(User, user_id)

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
        lat: Decimal.new("-1.2921000"),
        lng: Decimal.new("36.8219000")
      )

    driver
  end
end
