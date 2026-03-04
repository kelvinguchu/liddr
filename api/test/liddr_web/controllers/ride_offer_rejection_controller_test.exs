defmodule LiddrWeb.RideOfferRejectionControllerTest do
  use LiddrWeb.ConnCase, async: false

  import Ecto.Query

  alias Liddr.Accounts.User
  alias Liddr.Repo
  alias Liddr.Rides.RideOffer
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

  test "POST /api/rides/offers/:offer_id/reject marks offer rejected and dispatches next driver",
       %{
         conn: conn
       } do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)

    %{auth_conn: first_driver_conn, user_id: first_driver_id} =
      AuthFixtures.authenticate_driver!(conn)

    %{auth_conn: second_driver_conn, user_id: second_driver_id} =
      AuthFixtures.authenticate_driver!(conn)

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
        Decimal.new("-1.2929000"),
        Decimal.new("36.8226000")
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
               "offers" => [%{"id" => offer_id, "driver_id" => offered_driver_id}]
             }
           } = json_response(request_conn, 201)

    offered_conn_by_driver_id = %{
      first_driver_id => first_driver_conn,
      second_driver_id => second_driver_conn
    }

    offered_conn = Map.fetch!(offered_conn_by_driver_id, offered_driver_id)

    next_driver_id =
      if offered_driver_id == first_driver_id, do: second_driver_id, else: first_driver_id

    reject_conn = post(offered_conn, "/api/rides/offers/#{offer_id}/reject", %{})

    assert %{
             "data" => %{
               "ride" => %{"id" => ^ride_id},
               "offer" => %{
                 "id" => ^offer_id,
                 "status" => "rejected",
                 "responded_at" => responded_at
               }
             }
           } = json_response(reject_conn, 200)

    assert is_binary(responded_at)

    statuses =
      Repo.all(
        from o in RideOffer,
          where: o.ride_id == ^ride_id,
          select: {o.driver_id, o.status}
      )

    assert {offered_driver_id, "rejected"} in statuses
    assert {next_driver_id, "offered"} in statuses

    events_conn = get(rider_conn, "/api/rides/#{ride_id}/events")
    assert %{"data" => %{"events" => events}} = json_response(events_conn, 200)

    assert Enum.any?(events, &(&1["event_type"] == "offer_rejected"))

    assert Enum.any?(events, fn event ->
             event["event_type"] == "offer_created" and
               event["payload"]["driver_id"] == next_driver_id
           end)
  end

  test "POST /api/rides/offers/:offer_id/reject rejects offers owned by another driver", %{
    conn: conn
  } do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{user_id: owner_driver_id} = AuthFixtures.authenticate_driver!(conn)
    %{auth_conn: attacker_driver_conn} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()

    _ =
      create_eligible_driver_profile!(
        owner_driver_id,
        category_id,
        Decimal.new("-1.2921000"),
        Decimal.new("36.8219000")
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
               "offers" => [%{"id" => offer_id, "driver_id" => ^owner_driver_id}]
             }
           } = json_response(request_conn, 201)

    reject_conn = post(attacker_driver_conn, "/api/rides/offers/#{offer_id}/reject", %{})
    assert %{"error" => %{"code" => "OFFER_NOT_FOR_DRIVER"}} = json_response(reject_conn, 403)

    persisted_offer = Repo.get!(RideOffer, offer_id)
    assert persisted_offer.status == "offered"
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
end
