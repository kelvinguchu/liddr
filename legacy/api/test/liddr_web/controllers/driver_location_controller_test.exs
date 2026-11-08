defmodule LiddrWeb.DriverLocationControllerTest do
  use LiddrWeb.ConnCase, async: false

  alias Liddr.Accounts.User
  alias Liddr.Location.DriverLocation
  alias Liddr.Repo
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

  test "POST /api/drivers/me/location upserts driver location", %{conn: conn} do
    %{auth_conn: auth_conn, user_id: user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    user = Repo.get!(User, user_id)

    _driver =
      VerificationFixtures.create_driver!(
        user: user,
        vehicle_category_id: category_id,
        account_status: "active",
        verification_status: "approved",
        subscription_status: "active",
        is_available: true
      )

    conn =
      post(auth_conn, "/api/drivers/me/location", %{
        "lat" => "-1.2921",
        "lng" => "36.8219",
        "bearing" => 180,
        "speed_kmh" => 35
      })

    assert %{
             "data" => %{
               "driver_id" => ^user_id
             }
           } = json_response(conn, 200)

    persisted = Repo.get!(DriverLocation, user_id)
    assert is_binary(persisted.s2_cell_token)
    assert persisted.s2_cell_token != ""
    assert persisted.s2_cell_token =~ ~r/\A[0-9a-f]{1,16}\z/
  end
end
