defmodule LiddrWeb.AuthStepUpControllerTest do
  use LiddrWeb.ConnCase, async: true

  alias Liddr.Repo
  alias LiddrWeb.AuthFixtures

  test "POST /api/auth/step-up/challenges issues a challenge for authenticated ops", %{
    conn: _conn
  } do
    %{auth_conn: auth_conn} =
      AuthFixtures.authenticate_ops!("ops-step-up@example.com", enroll_totp: false)

    conn = post(auth_conn, "/api/auth/step-up/challenges", %{})

    assert %{
             "data" => %{
               "challenge_id" => challenge_id,
               "method" => "email_otp",
               "purpose" => "step_up",
               "channel" => "email",
               "debug_code" => debug_code
             }
           } = json_response(conn, 201)

    assert is_integer(challenge_id)
    assert is_binary(debug_code)
  end

  test "POST /api/auth/step-up/verify returns a short-lived step-up token", %{conn: _conn} do
    %{auth_conn: auth_conn} =
      AuthFixtures.authenticate_ops!("ops-step-up-verify@example.com", enroll_totp: false)

    challenge_conn = post(auth_conn, "/api/auth/step-up/challenges", %{})

    %{"data" => %{"challenge_id" => challenge_id, "debug_code" => debug_code}} =
      json_response(challenge_conn, 201)

    verify_conn =
      post(auth_conn, "/api/auth/step-up/verify", %{
        "challenge_id" => challenge_id,
        "code" => debug_code
      })

    assert %{
             "data" => %{
               "token_type" => "step_up",
               "step_up_token" => step_up_token,
               "expires_in" => expires_in
             }
           } = json_response(verify_conn, 200)

    assert is_binary(step_up_token)
    assert is_integer(expires_in)
  end

  test "POST /api/auth/mfa/totp/setup and confirm enrolls totp for ops", %{conn: _conn} do
    %{auth_conn: auth_conn, user_id: user_id} =
      AuthFixtures.authenticate_ops!("ops-mfa@example.com", enroll_totp: false)

    step_up_token = AuthFixtures.issue_step_up_token!(auth_conn)
    step_up_conn = put_req_header(auth_conn, "x-step-up-token", step_up_token)

    setup_conn =
      step_up_conn
      |> post("/api/auth/mfa/totp/setup", %{})

    assert %{
             "data" => %{
               "provider" => "totp",
               "setup_token" => setup_token,
               "secret" => secret,
               "otpauth_uri" => otpauth_uri
             }
           } = json_response(setup_conn, 201)

    assert is_binary(setup_token)
    assert is_binary(secret)
    assert String.starts_with?(otpauth_uri, "otpauth://totp/")

    confirm_conn =
      step_up_conn
      |> post("/api/auth/mfa/totp/confirm", %{
        "setup_token" => setup_token,
        "code" => Liddr.Auth.Totp.current_code(secret)
      })

    assert %{"data" => %{"provider" => "totp"}} = json_response(confirm_conn, 200)

    assert %Liddr.Auth.AuthIdentity{provider: "totp"} =
             Liddr.Auth.TotpEnrollment.active_identity(user_id)
  end

  test "POST /api/auth/step-up/challenges prefers totp when enrolled", %{conn: _conn} do
    %{auth_conn: auth_conn} = AuthFixtures.authenticate_ops!("ops-totp-step-up@example.com")
    secret = auth_conn.assigns.test_totp_secret

    challenge_conn = post(auth_conn, "/api/auth/step-up/challenges", %{})

    assert %{
             "data" => %{
               "challenge_id" => challenge_id,
               "method" => "totp",
               "purpose" => "step_up",
               "channel" => "totp"
             }
           } = json_response(challenge_conn, 201)

    assert String.starts_with?(challenge_id, "totp:")

    verify_conn =
      post(auth_conn, "/api/auth/step-up/verify", %{
        "challenge_id" => challenge_id,
        "code" => Liddr.Auth.Totp.current_code(secret)
      })

    assert %{"data" => %{"token_type" => "step_up", "step_up_token" => step_up_token}} =
             json_response(verify_conn, 200)

    assert is_binary(step_up_token)
  end

  test "POST /api/auth/step-up/verify rejects a replayed totp code", %{conn: _conn} do
    %{auth_conn: auth_conn} = AuthFixtures.authenticate_ops!("ops-totp-replay@example.com")
    code = Liddr.Auth.Totp.current_code(auth_conn.assigns.test_totp_secret)

    assert %{"data" => %{"step_up_token" => _token}} =
             auth_conn |> verify_totp(code) |> json_response(200)

    assert %{"error" => %{"code" => "INVALID_TOTP_CODE"}} =
             auth_conn |> verify_totp(code) |> json_response(401)
  end

  test "POST /api/auth/step-up/verify locks totp after repeated failures", %{conn: _conn} do
    %{auth_conn: auth_conn} = AuthFixtures.authenticate_ops!("ops-totp-lock@example.com")
    code = Liddr.Auth.Totp.current_code(auth_conn.assigns.test_totp_secret)
    wrong_code = wrong_totp_code(code)

    for _attempt <- 1..4 do
      assert %{"error" => %{"code" => "INVALID_TOTP_CODE"}} =
               auth_conn |> verify_totp(wrong_code) |> json_response(401)
    end

    assert %{"error" => %{"code" => "CHALLENGE_LOCKED"}} =
             auth_conn |> verify_totp(wrong_code) |> json_response(429)

    assert %{"error" => %{"code" => "CHALLENGE_LOCKED"}} =
             auth_conn |> verify_totp(code) |> json_response(429)
  end

  test "POST /api/auth/step-up/verify clears failures after a valid code", %{conn: _conn} do
    %{auth_conn: auth_conn, user_id: user_id} =
      AuthFixtures.authenticate_ops!("ops-totp-reset@example.com")

    code = Liddr.Auth.Totp.current_code(auth_conn.assigns.test_totp_secret)

    assert auth_conn |> verify_totp(wrong_totp_code(code)) |> json_response(401)
    assert auth_conn |> verify_totp(code) |> json_response(200)

    identity = Liddr.Auth.TotpEnrollment.active_identity(user_id)
    refute Map.has_key?(identity.metadata, "totp_failed_attempts")
    assert is_binary(identity.metadata["encrypted_secret"])
  end

  test "POST /api/auth/step-up/verify rejects a tampered totp challenge", %{conn: _conn} do
    %{auth_conn: auth_conn} = AuthFixtures.authenticate_ops!("ops-totp-tamper@example.com")

    conn =
      post(auth_conn, "/api/auth/step-up/verify", %{
        "challenge_id" => "totp:not-a-valid-token",
        "code" => "123456"
      })

    assert %{"error" => %{"code" => "INVALID_TOTP_TOKEN"}} = json_response(conn, 422)
  end

  test "ops/admin bootstrap endpoints remain reachable before totp enrollment", %{conn: _conn} do
    %{auth_conn: auth_conn} =
      AuthFixtures.authenticate_ops!("ops-bootstrap@example.com", enroll_totp: false)

    challenge_conn = post(auth_conn, "/api/auth/step-up/challenges", %{})
    assert %{"data" => %{"method" => "email_otp"}} = json_response(challenge_conn, 201)
  end

  test "high-risk ops route rejects missing step-up token", %{conn: _conn} do
    %{auth_conn: auth_conn} = AuthFixtures.authenticate_ops!("ops-step-up-block@example.com")
    target = Repo.insert!(%Liddr.Accounts.User{phone: AuthFixtures.unique_phone()})

    conn =
      post(auth_conn, "/api/moderation/enforcements", %{
        "user_id" => target.id,
        "action" => "warning"
      })

    assert %{"error" => %{"code" => "STEP_UP_REQUIRED"}} = json_response(conn, 403)
  end

  defp verify_totp(auth_conn, code) do
    %{"data" => %{"challenge_id" => challenge_id}} =
      auth_conn
      |> post("/api/auth/step-up/challenges", %{})
      |> json_response(201)

    post(auth_conn, "/api/auth/step-up/verify", %{"challenge_id" => challenge_id, "code" => code})
  end

  defp wrong_totp_code(code) do
    code
    |> String.to_integer()
    |> Kernel.+(1)
    |> rem(1_000_000)
    |> Integer.to_string()
    |> String.pad_leading(6, "0")
  end
end
