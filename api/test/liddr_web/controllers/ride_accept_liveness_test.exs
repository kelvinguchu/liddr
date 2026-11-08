defmodule LiddrWeb.RideAcceptLivenessTest do
  use LiddrWeb.ConnCase, async: false

  import Ecto.Query

  alias Liddr.Accounts.Driver
  alias Liddr.Accounts.User
  alias Liddr.Location.DriverLocation
  alias Liddr.Repo
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

  test "driver cannot accept an offer when location signal is stale", %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    driver_user = Repo.get!(User, driver_user_id)

    _driver =
      VerificationFixtures.create_driver!(
        user: driver_user,
        vehicle_category_id: category_id,
        account_status: "active",
        verification_status: "approved",
        subscription_status: "active",
        is_available: true
      )

    _ =
      VerificationFixtures.create_driver_location!(driver_user_id,
        lat: Decimal.new("-1.2921000"),
        lng: Decimal.new("36.8219000")
      )

    %{
      "data" => %{
        "offers" => [%{"id" => offer_id, "driver_id" => ^driver_user_id}]
      }
    } =
      post(rider_conn, "/api/rides/requests", %{
        "vehicle_category_id" => category_id,
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "offer_limit" => 1,
        "offer_ttl_seconds" => 60
      })
      |> json_response(201)

    stale_at =
      DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.add(-500, :second)

    _ =
      Repo.update_all(
        from(dl in DriverLocation, where: dl.driver_id == ^driver_user_id),
        set: [captured_at: stale_at]
      )

    _ =
      Repo.update_all(
        from(d in Driver, where: d.user_id == ^driver_user_id),
        set: [last_seen_at: stale_at]
      )

    assert %{"error" => %{"code" => "DRIVER_PRESENCE_UNHEALTHY"}} =
             post(driver_conn, "/api/rides/offers/#{offer_id}/accept", %{})
             |> json_response(403)
  end
end
