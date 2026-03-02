defmodule LiddrWeb.AuthFixtures do
  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint LiddrWeb.Endpoint

  alias Liddr.Accounts.User
  alias Liddr.Accounts.UserRole
  alias Liddr.Auth.Sessions
  alias Liddr.Repo

  def register_role!(conn, role, method, identifier) do
    register_conn =
      post(conn, "/api/auth/register/#{role}", %{
        "method" => method,
        "identifier" => identifier
      })

    register_conn |> Phoenix.ConnTest.json_response(201) |> get_in(["data", "user_id"])
  end

  def issue_otp_tokens!(method, identifier, purpose \\ "login") do
    challenge_conn =
      json_conn()
      |> post("/api/auth/challenges", %{
        "method" => method,
        "identifier" => identifier,
        "purpose" => purpose
      })

    %{"data" => %{"challenge_id" => challenge_id, "debug_code" => debug_code}} =
      Phoenix.ConnTest.json_response(challenge_conn, 201)

    verify_conn =
      json_conn()
      |> post("/api/auth/challenges/verify", %{
        "challenge_id" => challenge_id,
        "code" => debug_code
      })

    %{"data" => session_payload} = Phoenix.ConnTest.json_response(verify_conn, 200)

    %{
      challenge_id: challenge_id,
      debug_code: debug_code,
      access_token: session_payload["access_token"],
      refresh_token: session_payload["refresh_token"],
      token_type: session_payload["token_type"]
    }
  end

  def authenticate_rider!(conn, phone \\ unique_phone()) do
    authenticate_via_phone_otp!(conn, "rider", phone)
  end

  def authenticate_driver!(conn, phone \\ unique_phone()) do
    authenticate_via_phone_otp!(conn, "driver", phone)
  end

  def authenticate_ops!(email \\ unique_email("ops")) do
    authenticate_with_role!("ops", email: email)
  end

  def authenticate_with_role!(role, opts \\ []) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    user = create_user_for_role!(role, opts)
    Repo.insert!(%UserRole{user_id: user.id, role: role, granted_at: now})

    auth_method =
      Keyword.get(opts, :auth_method) ||
        if(role in ["ops", "admin"], do: "email_password", else: "phone_otp")

    session = Sessions.issue_session!(user.id, auth_method, now, %{})

    %{
      auth_conn: bearer_conn(session.access_token),
      user_id: user.id,
      access_token: session.access_token
    }
  end

  def bearer_conn(access_token) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{access_token}")
  end

  def unique_phone do
    suffix =
      System.unique_integer([:positive])
      |> Integer.to_string()
      |> String.pad_leading(8, "0")
      |> String.slice(-8, 8)

    "07" <> suffix
  end

  def unique_email(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}@example.com"

  defp authenticate_via_phone_otp!(conn, role, phone) do
    user_id = register_role!(conn, role, "phone_otp", phone)
    tokens = issue_otp_tokens!("phone_otp", phone, "login")

    %{
      auth_conn: bearer_conn(tokens.access_token),
      user_id: user_id,
      access_token: tokens.access_token,
      refresh_token: tokens.refresh_token
    }
  end

  defp create_user_for_role!(role, opts) do
    cond do
      email = Keyword.get(opts, :email) -> Repo.insert!(%User{email: email})
      phone = Keyword.get(opts, :phone) -> Repo.insert!(%User{phone: phone})
      role in ["ops", "admin"] -> Repo.insert!(%User{email: unique_email(role)})
      true -> Repo.insert!(%User{phone: unique_phone()})
    end
  end

  defp json_conn do
    build_conn()
    |> put_req_header("content-type", "application/json")
  end
end
