defmodule LiddrWeb.RatingOpsControllerTest do
  use LiddrWeb.ConnCase, async: false

  alias Liddr.Accounts.User
  alias Liddr.Repo
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

  setup do
    previous_security_mode = System.get_env("SECURITY_MODE")
    previous_ops_ip_allowlist = System.get_env("OPS_IP_ALLOWLIST")

    System.put_env("SECURITY_MODE", "observe")
    System.delete_env("OPS_IP_ALLOWLIST")

    on_exit(fn ->
      restore_env("SECURITY_MODE", previous_security_mode)
      restore_env("OPS_IP_ALLOWLIST", previous_ops_ip_allowlist)
    end)

    :ok
  end

  test "GET /api/ops/ratings lists ratings", %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    %{auth_conn: ops_conn} = AuthFixtures.authenticate_ops!("ops-ratings-list@example.com")
    category_id = VerificationFixtures.insert_vehicle_category!()
    _ = create_eligible_driver_profile!(driver_user_id, category_id)
    ride_id = create_completed_ride!(rider_conn, driver_conn, category_id)

    _ =
      post(rider_conn, "/api/rides/#{ride_id}/rate", %{
        "score" => 5
      })
      |> json_response(201)

    assert %{"data" => %{"ratings" => ratings}} =
             get(ops_conn, "/api/ops/ratings?ride_id=#{ride_id}") |> json_response(200)

    assert Enum.any?(ratings, &(&1["ride_id"] == ride_id))
  end

  test "GET /api/ops/ratings/excluded returns excluded ratings only", %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    %{auth_conn: ops_conn} = AuthFixtures.authenticate_ops!("ops-ratings-excluded@example.com")
    category_id = VerificationFixtures.insert_vehicle_category!()
    _ = create_eligible_driver_profile!(driver_user_id, category_id)
    ride_id = create_completed_ride!(rider_conn, driver_conn, category_id)

    _ =
      post(rider_conn, "/api/rides/#{ride_id}/rate", %{
        "score" => 1,
        "reason_tags" => ["traffic"]
      })
      |> json_response(201)

    assert %{"data" => %{"ratings" => [excluded_rating | _]}} =
             get(ops_conn, "/api/ops/ratings/excluded?ride_id=#{ride_id}") |> json_response(200)

    assert excluded_rating["ride_id"] == ride_id
    assert excluded_rating["include_in_score"] == false
  end

  test "POST /api/ops/ratings/:id/nullify and reinstate mutates score inclusion", %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)

    %{auth_conn: ops_conn, user_id: ops_user_id} =
      AuthFixtures.authenticate_ops!("ops-ratings-mutate@example.com")

    category_id = VerificationFixtures.insert_vehicle_category!()
    _ = create_eligible_driver_profile!(driver_user_id, category_id)
    ride_id = create_completed_ride!(rider_conn, driver_conn, category_id)

    %{"data" => %{"rating" => %{"id" => rating_id}}} =
      post(rider_conn, "/api/rides/#{ride_id}/rate", %{"score" => 5}) |> json_response(201)

    assert %{
             "data" => %{
               "rating" => %{
                 "id" => ^rating_id,
                 "include_in_score" => false,
                 "nullified_by_user_id" => ^ops_user_id,
                 "nullification_reason_code" => "manual_review_override"
               },
               "rated_user_stats" => %{"rating_count" => 0}
             }
           } =
             post(ops_conn, "/api/ops/ratings/#{rating_id}/nullify", %{
               "reason_code" => "manual_review_override",
               "note" => "Incorrect attribution from manual support review"
             })
             |> json_response(200)

    assert %{
             "data" => %{
               "rating" => %{
                 "id" => ^rating_id,
                 "include_in_score" => true,
                 "nullified_at" => nil,
                 "nullification_reason_code" => nil
               },
               "rated_user_stats" => %{"rating_count" => 1}
             }
           } =
             post(ops_conn, "/api/ops/ratings/#{rating_id}/reinstate", %{})
             |> json_response(200)
  end

  test "GET /api/ops/ratings/users/:rated_user_id/guardrails returns readiness snapshot", %{
    conn: conn
  } do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    %{auth_conn: ops_conn} = AuthFixtures.authenticate_ops!("ops-ratings-guardrails@example.com")
    category_id = VerificationFixtures.insert_vehicle_category!()
    _ = create_eligible_driver_profile!(driver_user_id, category_id)
    ride_id = create_completed_ride!(rider_conn, driver_conn, category_id)

    _ = post(rider_conn, "/api/rides/#{ride_id}/rate", %{"score" => 5}) |> json_response(201)

    assert %{
             "data" => %{
               "guardrails" => %{
                 "rated_user_id" => ^driver_user_id,
                 "recent_attributable_ratings" => count,
                 "minimum_required" => minimum_required,
                 "ready?" => ready?
               }
             }
           } =
             get(ops_conn, "/api/ops/ratings/users/#{driver_user_id}/guardrails")
             |> json_response(200)

    assert is_integer(count)
    assert is_integer(minimum_required)
    assert is_boolean(ready?)
  end

  defp create_completed_ride!(rider_conn, driver_conn, category_id) do
    %{"data" => %{"ride" => %{"id" => ride_id}, "offers" => [%{"id" => offer_id}]}} =
      rider_conn
      |> post("/api/rides/requests", %{
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

    _ =
      post(driver_conn, "/api/drivers/me/location", %{
        "lat" => "-1.3000",
        "lng" => "36.8000"
      })
      |> json_response(200)

    _ =
      post(driver_conn, "/api/rides/#{ride_id}/complete", %{
        "payment_mode" => "mpesa_direct",
        "final_fare_kes" => "250.00"
      })
      |> json_response(200)

    ride_id
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

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
