defmodule LiddrWeb.RideRatingSnapshotControllerTest do
  use LiddrWeb.ConnCase, async: false

  import Ecto.Query

  alias Decimal, as: D
  alias Liddr.Accounts.User
  alias Liddr.Repo
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

  test "ride and offer payloads expose rating snapshots across request, accept, show, and history",
       %{
         conn: conn
       } do
    %{auth_conn: rider_conn, user_id: rider_user_id} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()

    _ = create_eligible_driver_profile!(driver_user_id, category_id)
    update_user_rating!(rider_user_id, "4.91", 44)
    update_user_rating!(driver_user_id, "4.58", 8)

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
               "ride" => %{
                 "id" => ride_id,
                 "driver_rating_snapshot" => nil,
                 "rider_rating_snapshot" => %{
                   "rating_score" => 4.91,
                   "rating_count" => 44,
                   "confidence_band" => "high",
                   "is_new_rider" => false
                 }
               },
               "offers" => [
                 %{
                   "id" => offer_id,
                   "driver_id" => ^driver_user_id,
                   "driver_rating_snapshot" => %{
                     "rating_score" => 4.58,
                     "rating_count" => 8,
                     "confidence_band" => "low",
                     "is_new_driver" => true
                   },
                   "rider_rating_snapshot" => %{
                     "rating_count" => 44
                   }
                 }
               ]
             }
           } = json_response(request_conn, 201)

    accept_conn = post(driver_conn, "/api/rides/offers/#{offer_id}/accept", %{})

    assert %{
             "data" => %{
               "ride" => %{
                 "id" => ^ride_id,
                 "driver_id" => ^driver_user_id,
                 "driver_rating_snapshot" => %{
                   "rating_count" => 8,
                   "is_new_driver" => true
                 },
                 "rider_rating_snapshot" => %{"rating_count" => 44}
               },
               "offer" => %{
                 "driver_rating_snapshot" => %{
                   "rating_count" => 8,
                   "is_new_driver" => true
                 },
                 "rider_rating_snapshot" => %{"rating_count" => 44}
               }
             }
           } = json_response(accept_conn, 200)

    show_conn = get(rider_conn, "/api/rides/#{ride_id}")

    assert %{
             "data" => %{
               "ride" => %{
                 "id" => ^ride_id,
                 "driver_rating_snapshot" => %{"rating_count" => 8, "is_new_driver" => true},
                 "rider_rating_snapshot" => %{"rating_count" => 44, "is_new_rider" => false}
               }
             }
           } = json_response(show_conn, 200)

    rider_history_conn = get(rider_conn, "/api/rides/history/rider")
    driver_history_conn = get(driver_conn, "/api/rides/history/driver")

    assert %{"data" => %{"rides" => [rider_ride | _]}} = json_response(rider_history_conn, 200)
    assert rider_ride["driver_rating_snapshot"]["rating_count"] == 8
    assert rider_ride["rider_rating_snapshot"]["rating_count"] == 44

    assert %{"data" => %{"rides" => [driver_ride | _]}} = json_response(driver_history_conn, 200)
    assert driver_ride["driver_rating_snapshot"]["rating_count"] == 8
    assert driver_ride["rider_rating_snapshot"]["rating_count"] == 44
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
        lat: D.new("-1.2921000"),
        lng: D.new("36.8219000")
      )

    driver
  end

  defp update_user_rating!(user_id, score, count) do
    {1, _} =
      Repo.update_all(
        from(u in User, where: u.id == ^user_id),
        set: [
          rating_score: D.new(score),
          rating_count: count,
          rating_weighted_sum: D.new(score) |> D.mult(D.new(Integer.to_string(count))),
          rating_weight_total: D.new(Integer.to_string(count))
        ]
      )
  end
end
