defmodule LiddrWeb.RideMessageControllerTest do
  use LiddrWeb.ConnCase, async: false

  alias Liddr.Accounts.User
  alias Liddr.Repo
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

  test "rider and assigned driver can send/list/read ride messages", %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    _ = create_eligible_driver_profile!(driver_user_id, category_id)

    %{"data" => %{"ride" => %{"id" => ride_id}, "offers" => [%{"id" => offer_id}]}} =
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

    _ = post(driver_conn, "/api/rides/offers/#{offer_id}/accept", %{}) |> json_response(200)

    assert %{
             "data" => %{
               "message" => %{
                 "id" => message_id,
                 "ride_id" => ^ride_id,
                 "message_type" => "text",
                 "body" => "I am at the gate",
                 "read_at" => nil
               }
             }
           } =
             post(rider_conn, "/api/rides/#{ride_id}/messages", %{
               "message_type" => "text",
               "body" => "I am at the gate"
             })
             |> json_response(201)

    assert %{
             "data" => %{
               "messages" => messages,
               "unread_count" => 1
             }
           } = get(driver_conn, "/api/rides/#{ride_id}/messages") |> json_response(200)

    assert Enum.any?(messages, &(&1["id"] == message_id and &1["body"] == "I am at the gate"))

    assert %{
             "data" => %{
               "message" => %{
                 "id" => ^message_id,
                 "read_at" => read_at,
                 "acked_at" => acked_at
               }
             }
           } =
             post(driver_conn, "/api/rides/#{ride_id}/messages/#{message_id}/read", %{})
             |> json_response(200)

    assert is_binary(read_at)
    assert is_binary(acked_at)

    assert %{"error" => %{"code" => "RIDE_MESSAGE_NOT_FOR_USER"}} =
             post(rider_conn, "/api/rides/#{ride_id}/messages/#{message_id}/read", %{})
             |> json_response(403)
  end

  test "quick action message uses canonical body and metadata code", %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    _ = create_eligible_driver_profile!(driver_user_id, category_id)

    %{"data" => %{"ride" => %{"id" => ride_id}, "offers" => [%{"id" => offer_id}]}} =
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

    _ = post(driver_conn, "/api/rides/offers/#{offer_id}/accept", %{}) |> json_response(200)

    assert %{
             "data" => %{
               "message" => %{
                 "ride_id" => ^ride_id,
                 "message_type" => "quick_action",
                 "body" => "I am on my way",
                 "metadata" => %{"quick_action_code" => "on_my_way"}
               }
             }
           } =
             post(driver_conn, "/api/rides/#{ride_id}/messages", %{
               "message_type" => "quick_action",
               "quick_action_code" => "on_my_way"
             })
             |> json_response(201)
  end

  test "message send is blocked when ride has no assigned driver yet", %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    _ = create_eligible_driver_profile!(driver_user_id, category_id)

    %{"data" => %{"ride" => %{"id" => ride_id}}} =
      rider_conn
      |> post_ride_request(%{
        "vehicle_category_id" => category_id,
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "offer_limit" => 0
      })
      |> json_response(201)

    assert %{"error" => %{"code" => "RIDE_MESSAGE_DRIVER_NOT_ASSIGNED"}} =
             post(rider_conn, "/api/rides/#{ride_id}/messages", %{"body" => "Hello"})
             |> json_response(422)
  end

  test "unrelated user cannot access ride messages", %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    %{auth_conn: other_conn} = AuthFixtures.authenticate_rider!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    _ = create_eligible_driver_profile!(driver_user_id, category_id)

    %{"data" => %{"ride" => %{"id" => ride_id}, "offers" => [%{"id" => offer_id}]}} =
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

    _ = post(driver_conn, "/api/rides/offers/#{offer_id}/accept", %{}) |> json_response(200)

    assert %{"error" => %{"code" => "RIDE_MESSAGE_FORBIDDEN"}} =
             get(other_conn, "/api/rides/#{ride_id}/messages") |> json_response(403)
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
