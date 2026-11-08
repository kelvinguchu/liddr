defmodule LiddrWeb.AuthOtpDeliveryTest do
  use LiddrWeb.ConnCase, async: false

  import Ecto.Query

  alias Liddr.Auth.AuthChallenge
  alias Liddr.Repo
  alias LiddrWeb.AuthFixtures

  setup do
    previous_debug = Application.get_env(:liddr, :auth_debug_otp)
    previous_client = Application.get_env(:liddr, :otp_sms_client)
    previous_test_pid = Application.get_env(:liddr, :otp_sms_test_pid)
    previous_test_result = Application.get_env(:liddr, :otp_sms_test_result)

    Application.put_env(:liddr, :auth_debug_otp, false)
    Application.put_env(:liddr, :otp_sms_client, Liddr.TestSupport.OtpSmsTestClient)
    Application.put_env(:liddr, :otp_sms_test_pid, self())

    on_exit(fn ->
      restore_env(:auth_debug_otp, previous_debug)
      restore_env(:otp_sms_client, previous_client)
      restore_env(:otp_sms_test_pid, previous_test_pid)
      restore_env(:otp_sms_test_result, previous_test_result)
    end)

    :ok
  end

  test "POST /api/auth/challenges sends OTP SMS and hides debug code" do
    Application.put_env(:liddr, :otp_sms_test_result, :ok)

    identifier = AuthFixtures.unique_phone()

    {:ok, normalized_identifier} =
      Liddr.Auth.normalize_identifier_for_method("phone_otp", identifier)

    response =
      request_challenge(identifier)
      |> json_response(201)

    assert %{
             "data" => %{
               "challenge_id" => challenge_id,
               "method" => "phone_otp",
               "debug_code" => nil
             }
           } = response

    assert_receive {:otp_sms_sent, ^normalized_identifier, message}
    assert String.contains?(message, "verification code is")

    assert %AuthChallenge{id: ^challenge_id} = Repo.get(AuthChallenge, challenge_id)
  end

  test "POST /api/auth/challenges fails when OTP SMS provider fails and rolls back challenge" do
    Application.put_env(:liddr, :otp_sms_test_result, {:error, :gateway_down})

    identifier = AuthFixtures.unique_phone()

    assert %{"error" => %{"code" => "OTP_DELIVERY_UNAVAILABLE"}} =
             request_challenge(identifier)
             |> json_response(503)

    refute persisted_challenge_id(identifier)
  end

  defp request_challenge(identifier) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/auth/challenges", %{
      "method" => "phone_otp",
      "identifier" => identifier,
      "purpose" => "login"
    })
  end

  defp persisted_challenge_id(identifier) do
    {:ok, normalized_identifier} =
      Liddr.Auth.normalize_identifier_for_method("phone_otp", identifier)

    Repo.one(
      from challenge in AuthChallenge,
        where:
          challenge.provider == "phone_otp" and
            challenge.identity_value == ^normalized_identifier and
            challenge.purpose == "login",
        select: challenge.id
    )
  end

  defp restore_env(key, nil), do: Application.delete_env(:liddr, key)
  defp restore_env(key, value), do: Application.put_env(:liddr, key, value)
end
