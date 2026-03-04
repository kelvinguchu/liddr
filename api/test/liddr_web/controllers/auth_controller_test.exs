defmodule LiddrWeb.AuthControllerTest do
  use LiddrWeb.ConnCase, async: true

  import Ecto.Query

  alias Liddr.Accounts.User
  alias Liddr.Accounts.UserRole
  alias Liddr.Auth.AuthIdentity
  alias Liddr.Repo
  alias LiddrWeb.AuthFixtures

  test "GET /api/auth/methods returns supported methods", %{conn: conn} do
    conn = get(conn, "/api/auth/methods")

    assert %{"data" => %{"methods" => methods}} = json_response(conn, 200)
    assert Enum.any?(methods, fn method -> method["method"] == "phone_otp" end)
    assert Enum.any?(methods, fn method -> method["method"] == "google" end)
    refute Enum.any?(methods, fn method -> method["method"] == "email_password" end)
  end

  test "POST /api/auth/register/rider creates passenger identity and rider role", %{conn: conn} do
    payload = %{"method" => "phone_otp", "identifier" => "0712345678"}

    conn = post(conn, "/api/auth/register/rider", payload)

    assert %{
             "data" => %{
               "auth_method" => "phone_otp",
               "identifier" => "254712345678",
               "role" => "rider",
               "user_id" => user_id
             }
           } = json_response(conn, 201)

    rider_role =
      Repo.one(
        from ur in UserRole,
          where: ur.user_id == ^user_id and ur.role == "rider" and is_nil(ur.revoked_at)
      )

    assert %UserRole{role: "rider"} = rider_role

    assert %AuthIdentity{provider: "phone_otp"} =
             Repo.get_by(AuthIdentity,
               user_id: user_id,
               provider: "phone_otp",
               identifier_normalized: "254712345678"
             )
  end

  test "POST /api/auth/register/driver upgrades existing user to driver role", %{conn: conn} do
    rider_payload = %{"method" => "phone_otp", "identifier" => "0712345678"}
    _ = post(conn, "/api/auth/register/rider", rider_payload)

    conn = build_conn() |> put_req_header("content-type", "application/json")
    driver_payload = %{"method" => "phone_otp", "identifier" => "0712345678"}
    conn = post(conn, "/api/auth/register/driver", driver_payload)

    assert %{"data" => %{"role" => "driver", "user_id" => user_id}} =
             json_response(conn, 201)

    assert %UserRole{role: "driver"} = Repo.get_by(UserRole, user_id: user_id, role: "driver")
    assert %UserRole{role: "rider"} = Repo.get_by(UserRole, user_id: user_id, role: "rider")
  end

  test "POST /api/auth/challenges + verify issues session tokens", %{conn: conn} do
    _user_id = AuthFixtures.register_role!(conn, "rider", "phone_otp", "0712345678")
    tokens = AuthFixtures.issue_otp_tokens!("phone_otp", "0712345678", "login")

    assert is_integer(tokens.challenge_id)
    assert is_binary(tokens.debug_code)
    access_token = tokens.access_token
    refresh_token = tokens.refresh_token
    assert tokens.token_type == "bearer"
    assert is_binary(access_token)
    assert is_binary(refresh_token)
  end

  test "POST /api/auth/refresh rotates refresh token", %{conn: conn} do
    _user_id =
      AuthFixtures.register_role!(
        conn,
        "rider",
        "email_otp",
        "rider.refresh@example.com"
      )

    %{refresh_token: refresh_token} =
      AuthFixtures.issue_otp_tokens!("email_otp", "rider.refresh@example.com", "login")

    refresh_conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/auth/refresh", %{"refresh_token" => refresh_token})

    assert %{"data" => %{"refresh_token" => rotated_refresh_token}} =
             json_response(refresh_conn, 200)

    assert rotated_refresh_token != refresh_token
  end

  test "POST /api/auth/challenges blocks suspended accounts", %{conn: conn} do
    register_conn =
      post(conn, "/api/auth/register/rider", %{
        "method" => "phone_otp",
        "identifier" => "0712345699"
      })

    user_id = register_conn |> json_response(201) |> get_in(["data", "user_id"])
    user = Repo.get!(User, user_id)

    user
    |> User.account_status_changeset(%{account_status: "suspended"})
    |> Repo.update!()

    challenge_conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/auth/challenges", %{
        "method" => "phone_otp",
        "identifier" => "0712345699",
        "purpose" => "login"
      })

    assert %{"error" => %{"code" => "ACCOUNT_SUSPENDED"}} = json_response(challenge_conn, 403)
  end
end
