defmodule LiddrWeb.DriverAvailabilityControllerTest do
  use LiddrWeb.ConnCase, async: false

  alias Liddr.Accounts.Driver
  alias Liddr.Accounts.User
  alias Liddr.Repo
  alias Liddr.Verification.DriverActivityEvent
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

  test "POST /api/drivers/me/online requires driver role", %{conn: conn} do
    %{auth_conn: auth_conn} = AuthFixtures.authenticate_rider!(conn)

    conn = post(auth_conn, "/api/drivers/me/online", %{})

    assert %{"error" => %{"code" => "FORBIDDEN_ROLE"}} = json_response(conn, 403)
  end

  test "POST /api/drivers/me/online sets driver available when eligibility checks pass", %{
    conn: conn
  } do
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
        is_available: false
      )

    conn = post(auth_conn, "/api/drivers/me/online", %{})

    assert %{
             "data" => %{
               "user_id" => ^user_id,
               "is_available" => true,
               "subscription_status" => "active"
             }
           } = json_response(conn, 200)

    updated_driver = Repo.get!(Driver, user_id)
    assert updated_driver.is_available == true
    assert Repo.aggregate(DriverActivityEvent, :count, :id) == 1
  end

  test "POST /api/drivers/me/online blocks when subscription is not active", %{conn: conn} do
    %{auth_conn: auth_conn, user_id: user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    user = Repo.get!(User, user_id)

    _driver =
      VerificationFixtures.create_driver!(
        user: user,
        vehicle_category_id: category_id,
        account_status: "active",
        verification_status: "approved",
        subscription_status: "inactive",
        is_available: false
      )

    conn = post(auth_conn, "/api/drivers/me/online", %{})
    assert %{"error" => %{"code" => "DRIVER_SUBSCRIPTION_NOT_ACTIVE"}} = json_response(conn, 403)
  end

  test "POST /api/drivers/me/online blocks when subscription is grace", %{conn: conn} do
    %{auth_conn: auth_conn, user_id: user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    user = Repo.get!(User, user_id)

    _driver =
      VerificationFixtures.create_driver!(
        user: user,
        vehicle_category_id: category_id,
        account_status: "active",
        verification_status: "approved",
        subscription_status: "grace",
        is_available: false
      )

    conn = post(auth_conn, "/api/drivers/me/online", %{})

    assert %{"error" => %{"code" => "DRIVER_SUBSCRIPTION_NOT_ACTIVE"}} = json_response(conn, 403)
  end

  test "POST /api/drivers/me/offline sets driver offline", %{conn: conn} do
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

    conn = post(auth_conn, "/api/drivers/me/offline", %{})

    assert %{
             "data" => %{
               "user_id" => ^user_id,
               "is_available" => false
             }
           } = json_response(conn, 200)

    updated_driver = Repo.get!(Driver, user_id)
    assert updated_driver.is_available == false
  end
end
