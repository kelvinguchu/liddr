defmodule LiddrWeb.SendDeliveryControllerTest do
  use LiddrWeb.ConnCase, async: false

  import Ecto.Query

  alias Liddr.Accounts.User
  alias Liddr.Repo
  alias Liddr.Rides.SendDelivery
  alias Liddr.TestSupport.GCSMetadataStub
  alias Liddr.TestSupport.GCSUploadPresignerStub
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

  setup do
    previous_fetcher = Application.get_env(:liddr, :gcs_object_metadata_fetcher)
    previous_presigner = Application.get_env(:liddr, :gcs_upload_presigner)
    Application.put_env(:liddr, :gcs_object_metadata_fetcher, GCSMetadataStub)
    Application.put_env(:liddr, :gcs_upload_presigner, GCSUploadPresignerStub)
    :ok = GCSMetadataStub.reset()

    on_exit(fn ->
      restore_env(:gcs_object_metadata_fetcher, previous_fetcher)
      restore_env(:gcs_upload_presigner, previous_presigner)
    end)

    :ok
  end

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
      |> post_send_request(%{
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

    pickup_key = uploaded_proof!(ride_id, driver_user_id, "pickup")

    assert %{"data" => %{"delivery" => %{"pickup_proof_key" => ^pickup_key}}} =
             post(driver_conn, "/api/send/rides/#{ride_id}/pickup-proof", %{
               "pickup_proof_key" => pickup_key
             })
             |> json_response(201)

    _ = post(driver_conn, "/api/rides/#{ride_id}/start", %{}) |> json_response(200)

    _ =
      post(driver_conn, "/api/drivers/me/location", %{"lat" => "-1.3000", "lng" => "36.8000"})
      |> json_response(200)

    dropoff_key = uploaded_proof!(ride_id, driver_user_id, "dropoff")

    %{
      "data" => %{
        "recipient_confirmation_channel" => "in_app",
        "delivery" => %{"dropoff_proof_key" => ^dropoff_key}
      }
    } =
      post(driver_conn, "/api/send/rides/#{ride_id}/dropoff-proof", %{
        "dropoff_proof_key" => dropoff_key
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
      |> post_send_request(%{
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
        "pickup_proof_key" => uploaded_proof!(ride_id, driver_user_id, "pickup")
      })

    _ = post(driver_conn, "/api/rides/#{ride_id}/start", %{}) |> json_response(200)

    _ =
      post(driver_conn, "/api/drivers/me/location", %{"lat" => "-1.3000", "lng" => "36.8000"})
      |> json_response(200)

    _ =
      post(driver_conn, "/api/send/rides/#{ride_id}/dropoff-proof", %{
        "dropoff_proof_key" => uploaded_proof!(ride_id, driver_user_id, "dropoff")
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
      |> post_send_request(%{
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
        "pickup_proof_key" => uploaded_proof!(ride_id, driver_user_id, "pickup")
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
               "dropoff_proof_key" => uploaded_proof!(ride_id, driver_user_id, "dropoff")
             })
             |> json_response(201)

    assert %{"error" => %{"code" => "RECIPIENT_NOT_AUTHORIZED_FOR_DELIVERY"}} =
             post(outsider_conn, "/api/send/rides/#{ride_id}/recipient-confirm", %{})
             |> json_response(403)

    assert %{"data" => %{"notifications" => notifications}} =
             get(recipient_conn, "/api/notifications")
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

  test "proof upload URLs are scoped to the ride and driver", %{conn: conn} do
    %{driver_conn: driver_conn, driver_user_id: driver_id, ride_id: ride_id} =
      send_ride_at_pickup!(conn)

    assert %{"data" => %{"storage_key" => key, "upload_url" => url}} =
             post(driver_conn, "/api/send/rides/#{ride_id}/proof-uploads/presign", %{
               "proof_kind" => "pickup",
               "file_mime" => "image/jpeg",
               "file_size_bytes" => 2048
             })
             |> json_response(201)

    assert String.starts_with?(key, "send/proofs/#{ride_id}/pickup/#{driver_id}_")
    assert is_binary(url)
  end

  test "proof uploads reject non-image files", %{conn: conn} do
    %{driver_conn: driver_conn, ride_id: ride_id} = send_ride_at_pickup!(conn)

    assert %{"error" => %{"code" => "INVALID_FILE_MIME"}} =
             post(driver_conn, "/api/send/rides/#{ride_id}/proof-uploads/presign", %{
               "proof_kind" => "pickup",
               "file_mime" => "application/pdf",
               "file_size_bytes" => 2048
             })
             |> json_response(422)
  end

  test "a proof key must point to a file that was uploaded", %{conn: conn} do
    %{driver_conn: driver_conn, driver_user_id: driver_id, ride_id: ride_id} =
      send_ride_at_pickup!(conn)

    assert %{"error" => %{"code" => "PROOF_UPLOAD_NOT_FOUND"}} =
             post(driver_conn, "/api/send/rides/#{ride_id}/pickup-proof", %{
               "pickup_proof_key" => proof_key(ride_id, driver_id, "pickup")
             })
             |> json_response(422)
  end

  test "proof keys for another ride, driver, or made-up path are rejected", %{conn: conn} do
    %{driver_conn: driver_conn, driver_user_id: driver_id, ride_id: ride_id} =
      send_ride_at_pickup!(conn)

    invalid_keys = [
      "x",
      proof_key(ride_id + 1, driver_id, "pickup"),
      proof_key(ride_id, driver_id + 1, "pickup"),
      proof_key(ride_id, driver_id, "dropoff")
    ]

    for key <- invalid_keys do
      assert %{"error" => %{"code" => "INVALID_PROOF_KEY"}} =
               post(driver_conn, "/api/send/rides/#{ride_id}/pickup-proof", %{
                 "pickup_proof_key" => key
               })
               |> json_response(422)
    end
  end

  test "a recipient cannot confirm before the drop-off proof exists", %{conn: conn} do
    %{
      driver_conn: driver_conn,
      driver_user_id: driver_id,
      recipient_conn: recipient_conn,
      ride_id: ride_id
    } = send_ride_at_pickup!(conn)

    _ =
      post(driver_conn, "/api/send/rides/#{ride_id}/pickup-proof", %{
        "pickup_proof_key" => uploaded_proof!(ride_id, driver_id, "pickup")
      })
      |> json_response(201)

    assert %{"error" => %{"code" => "SEND_DROPOFF_PROOF_REQUIRED"}} =
             post(recipient_conn, "/api/send/rides/#{ride_id}/recipient-confirm", %{})
             |> json_response(422)
  end

  test "the drop-off proof cannot change after recipient confirmation", %{conn: conn} do
    %{
      driver_conn: driver_conn,
      driver_user_id: driver_id,
      recipient_conn: recipient_conn,
      ride_id: ride_id
    } = send_ride_at_pickup!(conn)

    _ =
      post(driver_conn, "/api/send/rides/#{ride_id}/pickup-proof", %{
        "pickup_proof_key" => uploaded_proof!(ride_id, driver_id, "pickup")
      })
      |> json_response(201)

    _ = post(driver_conn, "/api/rides/#{ride_id}/start", %{}) |> json_response(200)
    dropoff_key = uploaded_proof!(ride_id, driver_id, "dropoff")

    _ =
      post(driver_conn, "/api/send/rides/#{ride_id}/dropoff-proof", %{
        "dropoff_proof_key" => dropoff_key
      })
      |> json_response(201)

    _ =
      post(recipient_conn, "/api/send/rides/#{ride_id}/recipient-confirm", %{})
      |> json_response(200)

    assert %{"error" => %{"code" => "SEND_RECIPIENT_ALREADY_CONFIRMED"}} =
             post(driver_conn, "/api/send/rides/#{ride_id}/dropoff-proof", %{
               "dropoff_proof_key" => dropoff_key
             })
             |> json_response(422)
  end

  defp send_ride_at_pickup!(conn) do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)

    %{auth_conn: recipient_conn, user_id: recipient_user_id} =
      AuthFixtures.authenticate_rider!(conn)

    recipient_phone = Repo.get!(User, recipient_user_id).phone
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    send_category_id = VerificationFixtures.insert_vehicle_category!(%{slug: "send"})
    _ = create_eligible_driver_profile!(driver_user_id, send_category_id)

    %{"data" => %{"ride" => %{"id" => ride_id}, "offers" => [%{"id" => offer_id}]}} =
      rider_conn
      |> post_send_request(%{
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

    %{
      driver_conn: driver_conn,
      driver_user_id: driver_user_id,
      recipient_conn: recipient_conn,
      ride_id: ride_id
    }
  end

  defp proof_key(ride_id, driver_user_id, kind) do
    "send/proofs/#{ride_id}/#{kind}/#{driver_user_id}_proof.jpg"
  end

  defp uploaded_proof!(ride_id, driver_user_id, kind) do
    key = proof_key(ride_id, driver_user_id, kind)
    :ok = GCSMetadataStub.put_response(key, %{content_type: "image/jpeg", file_size_bytes: 2048})
    key
  end

  defp restore_env(key, nil), do: Application.delete_env(:liddr, key)
  defp restore_env(key, value), do: Application.put_env(:liddr, key, value)

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
