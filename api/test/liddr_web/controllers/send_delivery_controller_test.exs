defmodule LiddrWeb.SendDeliveryControllerTest do
  use LiddrWeb.ConnCase, async: false

  import Ecto.Query

  alias Liddr.Accounts.User
  alias Liddr.Repo
  alias Liddr.Rides.SendDelivery
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

  test "send proof flow gates start/complete until proofs + recipient confirmation", %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)

    %{auth_conn: recipient_conn, user_id: recipient_user_id} =
      AuthFixtures.authenticate_rider!(conn)

    recipient_phone = Repo.get!(User, recipient_user_id).phone
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    send_category_id = VerificationFixtures.insert_vehicle_category!(%{slug: "send"})
    _ = create_eligible_driver_profile!(driver_user_id, send_category_id)

    %{"data" => %{"ride" => %{"id" => ride_id}, "offers" => [%{"id" => offer_id}]}} =
      rider_conn
      |> post("/api/send/requests", %{
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "sender_name" => "Alice",
        "recipient_name" => "Bob",
        "recipient_phone" => recipient_phone,
        "item_description" => "Office parcel",
        "item_size" => "small",
        "payer" => "sender",
        "payment_timing" => "after",
        "offer_limit" => 1
      })
      |> json_response(201)

    _ = post(driver_conn, "/api/rides/offers/#{offer_id}/accept", %{}) |> json_response(200)
    _ = post(driver_conn, "/api/rides/#{ride_id}/arrived", %{}) |> json_response(200)

    assert %{"error" => %{"code" => "SEND_PICKUP_PROOF_REQUIRED"}} =
             post(driver_conn, "/api/rides/#{ride_id}/start", %{}) |> json_response(422)

    assert %{"data" => %{"delivery" => %{"pickup_proof_key" => "gcs://send/pickup-1.jpg"}}} =
             post(driver_conn, "/api/send/rides/#{ride_id}/pickup-proof", %{
               "pickup_proof_key" => "gcs://send/pickup-1.jpg"
             })
             |> json_response(201)

    _ = post(driver_conn, "/api/rides/#{ride_id}/start", %{}) |> json_response(200)

    _ =
      post(driver_conn, "/api/drivers/me/location", %{"lat" => "-1.3000", "lng" => "36.8000"})
      |> json_response(200)

    %{
      "data" => %{
        "recipient_confirmation_channel" => "in_app",
        "delivery" => %{"dropoff_proof_key" => "gcs://send/dropoff-1.jpg"}
      }
    } =
      post(driver_conn, "/api/send/rides/#{ride_id}/dropoff-proof", %{
        "dropoff_proof_key" => "gcs://send/dropoff-1.jpg"
      })
      |> json_response(201)

    assert %{"error" => %{"code" => "SEND_RECIPIENT_CONFIRMATION_PENDING"}} =
             post(driver_conn, "/api/rides/#{ride_id}/complete", %{
               "payment_mode" => "cash_direct",
               "final_fare_kes" => "150.00"
             })
             |> json_response(422)

    assert %{
             "data" => %{
               "ride_id" => ^ride_id,
               "delivery" => %{"recipient_confirmation_status" => "confirmed"}
             }
           } =
             post(recipient_conn, "/api/send/rides/#{ride_id}/recipient-confirm", %{})
             |> json_response(200)

    assert %{"data" => %{"ride" => %{"status" => "completed"}}} =
             post(driver_conn, "/api/rides/#{ride_id}/complete", %{
               "payment_mode" => "cash_direct",
               "final_fare_kes" => "150.00"
             })
             |> json_response(200)

    delivery = Repo.get_by!(SendDelivery, ride_id: ride_id)
    assert delivery.delivery_status == "completed"
    assert not is_nil(delivery.recipient_confirmed_at)
  end

  test "send completion succeeds without recipient confirmation after wait window", %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{user_id: recipient_user_id} = AuthFixtures.authenticate_rider!(conn)
    recipient_phone = Repo.get!(User, recipient_user_id).phone
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    send_category_id = VerificationFixtures.insert_vehicle_category!(%{slug: "send"})
    _ = create_eligible_driver_profile!(driver_user_id, send_category_id)

    %{"data" => %{"ride" => %{"id" => ride_id}, "offers" => [%{"id" => offer_id}]}} =
      rider_conn
      |> post("/api/send/requests", %{
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "sender_name" => "Alice",
        "recipient_name" => "Bob",
        "recipient_phone" => recipient_phone,
        "item_description" => "Office parcel",
        "item_size" => "small",
        "payer" => "sender",
        "payment_timing" => "after",
        "offer_limit" => 1
      })
      |> json_response(201)

    _ = post(driver_conn, "/api/rides/offers/#{offer_id}/accept", %{}) |> json_response(200)
    _ = post(driver_conn, "/api/rides/#{ride_id}/arrived", %{}) |> json_response(200)

    _ =
      post(driver_conn, "/api/send/rides/#{ride_id}/pickup-proof", %{
        "pickup_proof_key" => "gcs://send/pickup-2.jpg"
      })

    _ = post(driver_conn, "/api/rides/#{ride_id}/start", %{}) |> json_response(200)

    _ =
      post(driver_conn, "/api/drivers/me/location", %{"lat" => "-1.3000", "lng" => "36.8000"})
      |> json_response(200)

    _ =
      post(driver_conn, "/api/send/rides/#{ride_id}/dropoff-proof", %{
        "dropoff_proof_key" => "gcs://send/dropoff-2.jpg"
      })
      |> json_response(201)

    _ =
      Repo.update_all(
        from(d in SendDelivery, where: d.ride_id == ^ride_id),
        set: [dropoff_proof_captured_at: DateTime.add(DateTime.utc_now(), -700, :second)]
      )

    assert %{"data" => %{"ride" => %{"status" => "completed"}}} =
             post(driver_conn, "/api/rides/#{ride_id}/complete", %{
               "payment_mode" => "cash_direct",
               "final_fare_kes" => "140.00"
             })
             |> json_response(200)
  end

  test "public recipient confirmation endpoint is disabled", %{conn: conn} do
    assert %{"errors" => %{"detail" => "Not Found"}} =
             post(conn, "/api/send/recipient-confirmations/unknown-token", %{})
             |> json_response(404)
  end

  test "recipient confirmation prefers in-app flow for app recipients", %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)

    %{auth_conn: recipient_conn, user_id: recipient_user_id} =
      AuthFixtures.authenticate_rider!(conn)

    recipient_phone = Repo.get!(User, recipient_user_id).phone
    %{auth_conn: outsider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    send_category_id = VerificationFixtures.insert_vehicle_category!(%{slug: "send"})
    _ = create_eligible_driver_profile!(driver_user_id, send_category_id)

    %{"data" => %{"ride" => %{"id" => ride_id}, "offers" => [%{"id" => offer_id}]}} =
      rider_conn
      |> post("/api/send/requests", %{
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "sender_name" => "Alice",
        "recipient_name" => "In App Recipient",
        "recipient_phone" => recipient_phone,
        "item_description" => "Office parcel",
        "item_size" => "small",
        "payer" => "sender",
        "payment_timing" => "after",
        "offer_limit" => 1
      })
      |> json_response(201)

    _ = post(driver_conn, "/api/rides/offers/#{offer_id}/accept", %{}) |> json_response(200)
    _ = post(driver_conn, "/api/rides/#{ride_id}/arrived", %{}) |> json_response(200)

    _ =
      post(driver_conn, "/api/send/rides/#{ride_id}/pickup-proof", %{
        "pickup_proof_key" => "gcs://send/pickup-in-app.jpg"
      })
      |> json_response(201)

    _ = post(driver_conn, "/api/rides/#{ride_id}/start", %{}) |> json_response(200)

    _ =
      post(driver_conn, "/api/drivers/me/location", %{"lat" => "-1.3000", "lng" => "36.8000"})
      |> json_response(200)

    assert %{
             "data" => %{
               "recipient_confirmation_channel" => "in_app",
               "delivery" => %{"recipient_confirmation_status" => "pending"}
             }
           } =
             post(driver_conn, "/api/send/rides/#{ride_id}/dropoff-proof", %{
               "dropoff_proof_key" => "gcs://send/dropoff-in-app.jpg"
             })
             |> json_response(201)

    assert %{"error" => %{"code" => "RECIPIENT_NOT_AUTHORIZED_FOR_DELIVERY"}} =
             post(outsider_conn, "/api/send/rides/#{ride_id}/recipient-confirm", %{})
             |> json_response(403)

    assert %{"data" => %{"notifications" => notifications}} =
             get(recipient_conn, "/api/ride-notifications")
             |> json_response(200)

    assert Enum.any?(notifications, fn notification ->
             notification["event_type"] == "send_recipient_confirmation_required" and
               get_in(notification, ["payload", "ride_id"]) == ride_id
           end)

    assert %{
             "data" => %{
               "ride_id" => ^ride_id,
               "delivery" => %{"recipient_confirmation_status" => "confirmed"}
             }
           } =
             post(recipient_conn, "/api/send/rides/#{ride_id}/recipient-confirm", %{})
             |> json_response(200)
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
