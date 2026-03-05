defmodule LiddrWeb.RideOfferLockControllerTest do
  use LiddrWeb.ConnCase, async: false

  alias Liddr.Accounts.User
  alias Liddr.Repo
  alias Liddr.TestOfferLock
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures
  @blocked_event [:liddr, :rides, :offer_lock, :blocked]

  setup do
    previous_lock = Application.get_env(:liddr, :ride_offer_lock)
    previous_test_lock = Application.get_env(:liddr, TestOfferLock)
    handler_id = "ride-offer-lock-controller-test-#{System.unique_integer([:positive])}"

    Application.put_env(:liddr, :ride_offer_lock, TestOfferLock)

    :ok =
      :telemetry.attach(
        handler_id,
        @blocked_event,
        fn event, measurements, metadata, test_pid ->
          send(test_pid, {:offer_lock_blocked, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn ->
      restore_env(:ride_offer_lock, previous_lock)
      restore_env(TestOfferLock, previous_test_lock)
      :telemetry.detach(handler_id)
    end)

    :ok
  end

  test "request flow excludes drivers currently lock-held by another ride", %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{user_id: first_driver_id} = AuthFixtures.authenticate_driver!(conn)
    %{user_id: second_driver_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()

    _ =
      create_eligible_driver_profile!(
        first_driver_id,
        category_id,
        Decimal.new("-1.2921000"),
        Decimal.new("36.8219000")
      )

    _ =
      create_eligible_driver_profile!(
        second_driver_id,
        category_id,
        Decimal.new("-1.2922000"),
        Decimal.new("36.8220000")
      )

    Application.put_env(:liddr, TestOfferLock,
      locked_driver_ids: [first_driver_id],
      test_pid: self()
    )

    conn =
      post(rider_conn, "/api/rides/requests", %{
        "vehicle_category_id" => category_id,
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "offer_limit" => 2,
        "offer_ttl_seconds" => 30
      })

    assert %{"data" => %{"offers" => offers}} = json_response(conn, 201)

    offered_driver_ids =
      offers
      |> Enum.map(& &1["driver_id"])
      |> Enum.sort()

    assert offered_driver_ids == [second_driver_id]
  end

  test "reject flow releases driver offer lock for the ride", %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()

    _ =
      create_eligible_driver_profile!(
        driver_id,
        category_id,
        Decimal.new("-1.2921000"),
        Decimal.new("36.8219000")
      )

    Application.put_env(:liddr, TestOfferLock, test_pid: self(), locked_driver_ids: [])

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
               "offers" => [%{"id" => offer_id, "driver_id" => ^driver_id}]
             }
           } = json_response(request_conn, 201)

    reject_conn = post(driver_conn, "/api/rides/offers/#{offer_id}/reject", %{})
    assert %{"data" => %{"offer" => %{"status" => "rejected"}}} = json_response(reject_conn, 200)

    assert_receive {:test_offer_lock_released, ^driver_id, ^ride_id}, 1_000
  end

  test "request flow returns 503 when lock backend is unavailable and fallback is disabled", %{
    conn: conn
  } do
    previous_fallback =
      Application.get_env(:liddr, :ride_offer_lock_allow_unavailable_fallback, false)

    Application.put_env(:liddr, :ride_offer_lock_allow_unavailable_fallback, false)

    on_exit(fn ->
      restore_env(:ride_offer_lock_allow_unavailable_fallback, previous_fallback)
    end)

    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{user_id: driver_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()

    _ =
      create_eligible_driver_profile!(
        driver_id,
        category_id,
        Decimal.new("-1.2921000"),
        Decimal.new("36.8219000")
      )

    Application.put_env(:liddr, TestOfferLock,
      unavailable_driver_ids: [driver_id],
      test_pid: self()
    )

    conn =
      post(rider_conn, "/api/rides/requests", %{
        "vehicle_category_id" => category_id,
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "offer_limit" => 1,
        "offer_ttl_seconds" => 30
      })

    assert %{"error" => %{"code" => "DISPATCH_LOCK_BACKEND_UNAVAILABLE"}} =
             json_response(conn, 503)

    assert_receive {:offer_lock_blocked, @blocked_event, %{count: 1},
                    %{source: "request_initial_offers"}}
  end

  test "send request returns 503 when lock backend is unavailable and fallback is disabled", %{
    conn: conn
  } do
    previous_fallback =
      Application.get_env(:liddr, :ride_offer_lock_allow_unavailable_fallback, false)

    Application.put_env(:liddr, :ride_offer_lock_allow_unavailable_fallback, false)

    on_exit(fn ->
      restore_env(:ride_offer_lock_allow_unavailable_fallback, previous_fallback)
    end)

    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{user_id: recipient_user_id} = AuthFixtures.authenticate_rider!(conn)
    recipient_phone = Repo.get!(User, recipient_user_id).phone
    %{user_id: driver_id} = AuthFixtures.authenticate_driver!(conn)
    send_category_id = VerificationFixtures.insert_vehicle_category!(%{slug: "send"})

    _ =
      create_eligible_driver_profile!(
        driver_id,
        send_category_id,
        Decimal.new("-1.2921000"),
        Decimal.new("36.8219000")
      )

    Application.put_env(:liddr, TestOfferLock,
      unavailable_driver_ids: [driver_id],
      test_pid: self()
    )

    conn =
      post(rider_conn, "/api/send/requests", %{
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "sender_name" => "Alice",
        "recipient_name" => "Bob",
        "recipient_phone" => recipient_phone,
        "item_description" => "Small package",
        "item_size" => "small",
        "payer" => "sender",
        "payment_timing" => "after"
      })

    assert %{"error" => %{"code" => "DISPATCH_LOCK_BACKEND_UNAVAILABLE"}} =
             json_response(conn, 503)

    assert_receive {:offer_lock_blocked, @blocked_event, %{count: 1},
                    %{source: "request_initial_offers"}}
  end

  defp create_eligible_driver_profile!(user_id, category_id, lat, lng) do
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

    _ = VerificationFixtures.create_driver_location!(driver.user_id, lat: lat, lng: lng)
    driver
  end

  defp restore_env(key, nil), do: Application.delete_env(:liddr, key)
  defp restore_env(key, value), do: Application.put_env(:liddr, key, value)
end
