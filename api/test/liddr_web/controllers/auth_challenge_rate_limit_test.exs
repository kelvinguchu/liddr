defmodule LiddrWeb.AuthChallengeRateLimitTest do
  use LiddrWeb.ConnCase, async: false

  alias LiddrWeb.AuthFixtures

  @policy_key Liddr.Auth.ChallengeRateLimiter

  setup do
    previous_policy = Application.get_env(:liddr, @policy_key)

    on_exit(fn ->
      restore_env(@policy_key, previous_policy)
    end)

    :ok
  end

  test "POST /api/auth/challenges applies cooldown for same identifier and purpose" do
    put_policy!(
      cooldown_seconds: 60,
      identity_window_seconds: 900,
      identity_max_requests: 10,
      ip_window_seconds: 900,
      ip_max_requests: 10_000,
      device_window_seconds: 900,
      device_max_requests: 10_000
    )

    identifier = AuthFixtures.unique_phone()
    payload = %{"method" => "phone_otp", "identifier" => identifier, "purpose" => "login"}

    assert %{"data" => %{"challenge_id" => _id}} =
             request_challenge(payload) |> json_response(201)

    assert %{"error" => %{"code" => "CHALLENGE_RATE_LIMITED"}} =
             request_challenge(payload) |> json_response(429)
  end

  test "POST /api/auth/challenges applies identifier window limits across purposes" do
    put_policy!(
      cooldown_seconds: 60,
      identity_window_seconds: 900,
      identity_max_requests: 2,
      ip_window_seconds: 900,
      ip_max_requests: 10_000,
      device_window_seconds: 900,
      device_max_requests: 10_000
    )

    identifier = AuthFixtures.unique_phone()

    assert %{"data" => %{"challenge_id" => _id}} =
             request_challenge(%{
               "method" => "phone_otp",
               "identifier" => identifier,
               "purpose" => "login"
             })
             |> json_response(201)

    assert %{"data" => %{"challenge_id" => _id}} =
             request_challenge(%{
               "method" => "phone_otp",
               "identifier" => identifier,
               "purpose" => "step_up"
             })
             |> json_response(201)

    assert %{"error" => %{"code" => "CHALLENGE_RATE_LIMITED"}} =
             request_challenge(%{
               "method" => "phone_otp",
               "identifier" => identifier,
               "purpose" => "recover_account"
             })
             |> json_response(429)
  end

  test "POST /api/auth/challenges applies per-IP window limits" do
    put_policy!(
      cooldown_seconds: 60,
      identity_window_seconds: 900,
      identity_max_requests: 100,
      ip_window_seconds: 900,
      ip_max_requests: 2,
      device_window_seconds: 900,
      device_max_requests: 10_000
    )

    assert %{"data" => %{"challenge_id" => _id}} =
             request_challenge(%{
               "method" => "phone_otp",
               "identifier" => AuthFixtures.unique_phone(),
               "purpose" => "login"
             })
             |> json_response(201)

    assert %{"data" => %{"challenge_id" => _id}} =
             request_challenge(%{
               "method" => "phone_otp",
               "identifier" => AuthFixtures.unique_phone(),
               "purpose" => "login"
             })
             |> json_response(201)

    assert %{"error" => %{"code" => "CHALLENGE_RATE_LIMITED"}} =
             request_challenge(%{
               "method" => "phone_otp",
               "identifier" => AuthFixtures.unique_phone(),
               "purpose" => "login"
             })
             |> json_response(429)
  end

  test "POST /api/auth/challenges applies per-device window limits" do
    put_policy!(
      cooldown_seconds: 60,
      identity_window_seconds: 900,
      identity_max_requests: 100,
      ip_window_seconds: 900,
      ip_max_requests: 10_000,
      device_window_seconds: 900,
      device_max_requests: 2
    )

    headers = [{"x-device-id", "otp-device-limit"}]

    assert %{"data" => %{"challenge_id" => _id}} =
             request_challenge(
               %{
                 "method" => "phone_otp",
                 "identifier" => AuthFixtures.unique_phone(),
                 "purpose" => "login"
               },
               headers
             )
             |> json_response(201)

    assert %{"data" => %{"challenge_id" => _id}} =
             request_challenge(
               %{
                 "method" => "phone_otp",
                 "identifier" => AuthFixtures.unique_phone(),
                 "purpose" => "login"
               },
               headers
             )
             |> json_response(201)

    assert %{"error" => %{"code" => "CHALLENGE_RATE_LIMITED"}} =
             request_challenge(
               %{
                 "method" => "phone_otp",
                 "identifier" => AuthFixtures.unique_phone(),
                 "purpose" => "login"
               },
               headers
             )
             |> json_response(429)
  end

  defp request_challenge(payload, headers \\ []) do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_headers(headers)

    post(conn, "/api/auth/challenges", payload)
  end

  defp put_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {key, value}, acc -> put_req_header(acc, key, value) end)
  end

  defp put_policy!(attrs) do
    Application.put_env(:liddr, @policy_key, attrs)
  end

  defp restore_env(key, nil), do: Application.delete_env(:liddr, key)
  defp restore_env(key, value), do: Application.put_env(:liddr, key, value)
end
