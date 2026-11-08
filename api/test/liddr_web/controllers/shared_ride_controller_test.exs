defmodule LiddrWeb.SharedRideControllerTest do
  use LiddrWeb.ConnCase, async: false

  import Ecto.Query

  alias Liddr.Accounts.User
  alias Liddr.Repo
  alias Liddr.Rides.Execution.GeoPolicy
  alias Liddr.Rides.Ride
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

  test "shared context is available to rider and assigned driver", %{conn: conn} do
    %{rider_conn: rider_conn, driver_conn: driver_conn, ride_id: ride_id, offer_id: offer_id} =
      create_shared_offer!(conn)

    assert %{
             "data" => %{
               "ride" => %{"id" => ^ride_id, "product_type" => "shared"},
               "group" => %{"ride_id" => ^ride_id, "max_members" => 2},
               "members" => [%{"ride_id" => ^ride_id, "status" => "requested"}],
               "stops" => stops,
               "next_stop" => %{
                 "stop_type" => "pickup",
                 "status" => "pending",
                 "eta_at" => next_stop_eta_at
               }
             }
           } = get(rider_conn, "/api/rides/#{ride_id}/shared") |> json_response(200)

    assert is_binary(next_stop_eta_at)
    assert length(stops) == 2
    assert Enum.any?(stops, &(&1["stop_type"] == "pickup"))
    assert Enum.any?(stops, &(&1["stop_type"] == "dropoff"))

    _ = post(driver_conn, "/api/rides/offers/#{offer_id}/accept", %{}) |> json_response(200)

    assert %{
             "data" => %{
               "ride" => %{"id" => ^ride_id, "status" => "accepted"},
               "members" => [%{"ride_id" => ^ride_id, "status" => "requested"}]
             }
           } = get(driver_conn, "/api/rides/#{ride_id}/shared") |> json_response(200)
  end

  test "rider can cancel their shared member and ride cancellation is enforced", %{conn: conn} do
    %{rider_conn: rider_conn, driver_conn: driver_conn, ride_id: ride_id, offer_id: offer_id} =
      create_shared_offer!(conn)

    _ = post(driver_conn, "/api/rides/offers/#{offer_id}/accept", %{}) |> json_response(200)

    %{"data" => %{"members" => [%{"id" => member_id}]}} =
      get(rider_conn, "/api/rides/#{ride_id}/shared") |> json_response(200)

    assert %{
             "data" => %{
               "ride" => %{
                 "id" => ^ride_id,
                 "status" => "cancelled",
                 "cancellation_reason_code" => "rider_changed_mind"
               },
               "members" => [%{"id" => ^member_id, "status" => "cancelled"}]
             }
           } =
             post(rider_conn, "/api/rides/#{ride_id}/shared/members/#{member_id}/cancel", %{
               "reason" => "rider_changed_mind"
             })
             |> json_response(200)
  end

  test "driver can mark shared member as no-show after wait window", %{conn: conn} do
    %{driver_conn: driver_conn, ride_id: ride_id, offer_id: offer_id} = create_shared_offer!(conn)

    _ = post(driver_conn, "/api/rides/offers/#{offer_id}/accept", %{}) |> json_response(200)
    _ = post(driver_conn, "/api/rides/#{ride_id}/arrived", %{}) |> json_response(200)

    wait_seconds = GeoPolicy.no_show_wait_seconds()
    stale_arrived_at = DateTime.utc_now() |> DateTime.add(-(wait_seconds + 5), :second)

    _ =
      Repo.update_all(
        from(r in Ride, where: r.id == ^ride_id),
        set: [arrived_at: stale_arrived_at]
      )

    %{"data" => %{"members" => [%{"id" => member_id}]}} =
      get(driver_conn, "/api/rides/#{ride_id}/shared") |> json_response(200)

    assert %{
             "data" => %{
               "ride" => %{
                 "id" => ^ride_id,
                 "status" => "cancelled",
                 "cancellation_reason_code" => "rider_no_show"
               },
               "members" => [%{"id" => ^member_id, "status" => "no_show"}]
             }
           } =
             post(driver_conn, "/api/rides/#{ride_id}/shared/members/#{member_id}/no-show", %{})
             |> json_response(200)
  end

  test "driver can progress shared member pickup and dropoff lifecycle", %{conn: conn} do
    %{driver_conn: driver_conn, ride_id: ride_id, offer_id: offer_id} = create_shared_offer!(conn)
    _ = post(driver_conn, "/api/rides/offers/#{offer_id}/accept", %{}) |> json_response(200)

    %{"data" => %{"members" => [%{"id" => member_id}]}} =
      get(driver_conn, "/api/rides/#{ride_id}/shared") |> json_response(200)

    assert %{
             "data" => %{
               "members" => members_after_arrive,
               "stops" => stops_after_arrive
             }
           } =
             post(
               driver_conn,
               "/api/rides/#{ride_id}/shared/members/#{member_id}/arrive-pickup",
               %{}
             )
             |> json_response(200)

    assert Enum.any?(
             members_after_arrive,
             &(&1["id"] == member_id and &1["status"] == "pickup_pending")
           )

    dropoff_eta_before_pickup =
      stops_after_arrive
      |> Enum.find(&(&1["member_id"] == member_id and &1["stop_type"] == "dropoff"))
      |> Map.fetch!("eta_at")

    assert %{
             "data" => %{
               "members" => members_after_pickup,
               "stops" => stops_after_pickup,
               "next_stop" => %{"eta_at" => dropoff_eta_after_pickup}
             }
           } =
             post(
               driver_conn,
               "/api/rides/#{ride_id}/shared/members/#{member_id}/picked-up",
               %{}
             )
             |> json_response(200)

    assert Enum.any?(
             members_after_pickup,
             &(&1["id"] == member_id and &1["status"] == "picked_up")
           )

    assert Enum.any?(
             stops_after_pickup,
             &(&1["member_id"] == member_id and &1["stop_type"] == "pickup" and
                 &1["status"] == "completed")
           )

    assert dropoff_eta_after_pickup != dropoff_eta_before_pickup

    assert %{"data" => %{"members" => members_after_dropoff, "stops" => stops_after_dropoff}} =
             post(
               driver_conn,
               "/api/rides/#{ride_id}/shared/members/#{member_id}/dropped-off",
               %{}
             )
             |> json_response(200)

    assert Enum.any?(
             members_after_dropoff,
             &(&1["id"] == member_id and &1["status"] == "dropped_off")
           )

    assert Enum.any?(
             stops_after_dropoff,
             &(&1["member_id"] == member_id and &1["stop_type"] == "dropoff" and
                 &1["status"] == "completed")
           )
  end

  test "shared member dropoff is rejected before pickup", %{conn: conn} do
    %{driver_conn: driver_conn, ride_id: ride_id, offer_id: offer_id} = create_shared_offer!(conn)
    _ = post(driver_conn, "/api/rides/offers/#{offer_id}/accept", %{}) |> json_response(200)

    %{"data" => %{"members" => [%{"id" => member_id}]}} =
      get(driver_conn, "/api/rides/#{ride_id}/shared") |> json_response(200)

    assert %{"error" => %{"code" => "SHARED_MEMBER_NOT_DROPOFF_READY"}} =
             post(
               driver_conn,
               "/api/rides/#{ride_id}/shared/members/#{member_id}/dropped-off",
               %{}
             )
             |> json_response(422)
  end

  test "driver location ping refreshes shared next stop ETA", %{conn: conn} do
    %{driver_conn: driver_conn, ride_id: ride_id, offer_id: offer_id} = create_shared_offer!(conn)
    _ = post(driver_conn, "/api/rides/offers/#{offer_id}/accept", %{}) |> json_response(200)

    %{"data" => %{"next_stop" => %{"eta_at" => eta_before}}} =
      get(driver_conn, "/api/rides/#{ride_id}/shared") |> json_response(200)

    _ =
      post(driver_conn, "/api/drivers/me/location", %{
        "lat" => "-1.1000",
        "lng" => "36.9000"
      })
      |> json_response(200)

    %{"data" => %{"next_stop" => %{"eta_at" => eta_after}}} =
      get(driver_conn, "/api/rides/#{ride_id}/shared") |> json_response(200)

    before_dt = parse_datetime!(eta_before)
    after_dt = parse_datetime!(eta_after)

    assert DateTime.compare(after_dt, before_dt) == :gt
    assert DateTime.diff(after_dt, before_dt, :second) >= 300

    assert %{"data" => %{"notifications" => notifications}} =
             get(driver_conn, "/api/notifications?limit=20")
             |> json_response(200)

    assert Enum.any?(notifications, fn row ->
             row["ride_id"] == ride_id and row["event_type"] == "shared_eta_updated" and
               is_map(row["payload"]) and row["payload"]["ride_id"] == ride_id and
               is_map(row["payload"]["next_stop"]) and
               is_nil(row["payload"]["ride"])
           end)
  end

  defp create_shared_offer!(conn) do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!(%{slug: "basic"})
    _ = create_eligible_driver_profile!(driver_user_id, category_id)

    %{"data" => %{"ride" => %{"id" => ride_id}, "offers" => [%{"id" => offer_id}]}} =
      post_ride_request(rider_conn, %{
        "vehicle_category_id" => category_id,
        "product_type" => "shared",
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "offer_limit" => 1
      })
      |> json_response(201)

    %{rider_conn: rider_conn, driver_conn: driver_conn, ride_id: ride_id, offer_id: offer_id}
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

  defp parse_datetime!(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> flunk("invalid datetime: #{inspect(value)}")
    end
  end
end
