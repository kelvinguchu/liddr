defmodule LiddrWeb.RideActionSecurityControllerTest do
  use LiddrWeb.ConnCase, async: false

  alias Liddr.Rides.ActionSecuritySignals
  alias Liddr.TestSupport.FakeRedis
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

  setup do
    previous_policy = Application.get_env(:liddr, ActionSecuritySignals)
    previous_mode = System.get_env("SECURITY_MODE")

    on_exit(fn ->
      restore_app_env(ActionSecuritySignals, previous_policy)
      restore_system_env("SECURITY_MODE", previous_mode)
    end)

    FakeRedis.reset!()

    Application.put_env(:liddr, ActionSecuritySignals,
      enabled: true,
      ip_window_seconds: 600,
      ip_max_events: 10_000,
      ip_max_distinct_users: 10_000,
      device_window_seconds: 600,
      device_max_events: 10_000,
      device_max_distinct_users: 2,
      enforce_ip_on_enforce_mode: false,
      redis_module: FakeRedis
    )

    System.put_env("SECURITY_MODE", "enforce")
    :ok
  end

  test "POST /api/rides/requests returns 429 for secondary security device signal", %{conn: conn} do
    %{auth_conn: rider_one_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: rider_two_conn} = AuthFixtures.authenticate_rider!(conn)

    category_id = VerificationFixtures.insert_vehicle_category!()
    payload = valid_request_payload(category_id)
    shared_device = "ios-shared-device-001"

    assert %{"data" => %{"ride" => %{"id" => _ride_id}}} =
             rider_one_conn
             |> put_req_header("x-device-id", shared_device)
             |> post("/api/rides/requests", payload)
             |> json_response(201)

    assert %{"error" => %{"code" => "RIDE_ACTION_SECURITY_RATE_LIMITED"}} =
             rider_two_conn
             |> put_req_header("x-device-id", shared_device)
             |> post("/api/rides/requests", payload)
             |> json_response(429)
  end

  defp valid_request_payload(category_id) do
    %{
      "vehicle_category_id" => category_id,
      "pickup_lat" => "-1.2921",
      "pickup_lng" => "36.8219",
      "dropoff_lat" => "-1.3000",
      "dropoff_lng" => "36.8000",
      "offer_limit" => 0
    }
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:liddr, key)
  defp restore_app_env(key, value), do: Application.put_env(:liddr, key, value)

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end
