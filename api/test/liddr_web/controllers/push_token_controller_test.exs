defmodule LiddrWeb.PushTokenControllerTest do
  use LiddrWeb.ConnCase, async: false

  import Ecto.Query

  alias Liddr.Repo
  alias Liddr.Rides.UserPushToken
  alias LiddrWeb.AuthFixtures

  test "POST /api/push-tokens registers and upserts a token", %{conn: conn} do
    %{auth_conn: rider_conn, user_id: user_id} = AuthFixtures.authenticate_rider!(conn)
    token = "fcm_test_token_1234567890"

    assert %{"data" => %{"push_token" => %{"provider" => "fcm", "platform" => "android"}}} =
             post(rider_conn, "/api/push-tokens", %{
               "token" => token,
               "platform" => "android",
               "device_id" => "pixel-1"
             })
             |> json_response(200)

    assert %{"data" => %{"push_token" => %{"platform" => "ios", "device_id" => "iphone-1"}}} =
             post(rider_conn, "/api/push-tokens", %{
               "token" => token,
               "platform" => "ios",
               "device_id" => "iphone-1"
             })
             |> json_response(200)

    persisted =
      Repo.one!(
        from t in UserPushToken,
          where: t.user_id == ^user_id and t.token == ^token and is_nil(t.revoked_at)
      )

    assert persisted.platform == "ios"
    assert persisted.device_id == "iphone-1"
  end

  test "DELETE /api/push-tokens revokes by token", %{conn: conn} do
    %{auth_conn: driver_conn, user_id: user_id} = AuthFixtures.authenticate_driver!(conn)
    token = "fcm_test_token_abcdefghijklmnop"
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    _ =
      Repo.insert!(%UserPushToken{
        user_id: user_id,
        provider: "fcm",
        platform: "android",
        token: token,
        device_id: "android-xyz",
        last_seen_at: now,
        metadata: %{}
      })

    assert %{"data" => %{"revoked" => true}} =
             delete(driver_conn, "/api/push-tokens", %{"token" => token}) |> json_response(200)

    revoked = Repo.get_by!(UserPushToken, token: token)
    refute is_nil(revoked.revoked_at)
  end

  test "invalid push-token payload is rejected", %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)

    assert %{"error" => %{"code" => "INVALID_PUSH_TOKEN"}} =
             post(rider_conn, "/api/push-tokens", %{"platform" => "android"})
             |> json_response(422)
  end
end
