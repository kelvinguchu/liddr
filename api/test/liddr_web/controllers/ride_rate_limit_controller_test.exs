defmodule LiddrWeb.RideRateLimitControllerTest do
  use LiddrWeb.ConnCase, async: false

  alias Liddr.Accounts.Driver
  alias Liddr.Accounts.User
  alias Liddr.Repo
  alias Liddr.Rides.Ride
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

  @strict_policy [
    ride_request_window_seconds: 3600,
    ride_request_max_requests: 1,
    rider_cancel_window_seconds: 3600,
    rider_cancel_max_actions: 1,
    driver_cancel_window_seconds: 3600,
    driver_cancel_max_actions: 1,
    driver_no_show_window_seconds: 3600,
    driver_no_show_max_actions: 1,
    message_send_window_seconds: 3600,
    message_send_max_messages: 1
  ]

  setup do
    previous_policy = Application.get_env(:liddr, Liddr.Rides.ActionRateLimiter)
    Application.put_env(:liddr, Liddr.Rides.ActionRateLimiter, @strict_policy)

    on_exit(fn ->
      if is_nil(previous_policy) do
        Application.delete_env(:liddr, Liddr.Rides.ActionRateLimiter)
      else
        Application.put_env(:liddr, Liddr.Rides.ActionRateLimiter, previous_policy)
      end
    end)

    :ok
  end

  test "POST /api/rides/requests returns 429 when rider request window exceeded", %{conn: conn} do
    %{auth_conn: rider_conn, user_id: rider_id} = AuthFixtures.authenticate_rider!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    insert_ride!(%{
      rider_id: rider_id,
      vehicle_category_id: category_id,
      status: "requested",
      requested_at: now
    })

    response = post_ride_request(rider_conn, %{}) |> json_response(429)
    assert get_in(response, ["error", "code"]) == "RIDE_REQUEST_RATE_LIMITED"
  end

  test "POST /api/rides/:ride_id/cancel returns 429 when rider cancel window exceeded", %{
    conn: conn
  } do
    %{auth_conn: rider_conn, user_id: rider_id} = AuthFixtures.authenticate_rider!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    insert_ride!(%{
      rider_id: rider_id,
      vehicle_category_id: category_id,
      status: "cancelled",
      requested_at: DateTime.add(now, -120, :second),
      cancelled_at: now,
      cancelled_by_user_id: rider_id,
      cancellation_reason_code: "changed_mind"
    })

    response = post(rider_conn, "/api/rides/999999/cancel", %{}) |> json_response(429)
    assert get_in(response, ["error", "code"]) == "RIDER_CANCEL_RATE_LIMITED"
  end

  test "POST /api/rides/:ride_id/driver-cancel returns 429 when driver cancel window exceeded", %{
    conn: conn
  } do
    %{auth_conn: driver_conn, user_id: driver_id} = AuthFixtures.authenticate_driver!(conn)
    rider = VerificationFixtures.create_user!()
    category_id = VerificationFixtures.insert_vehicle_category!()
    ensure_driver_profile!(driver_id, category_id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    insert_ride!(%{
      rider_id: rider.id,
      driver_id: driver_id,
      vehicle_category_id: category_id,
      status: "cancelled",
      requested_at: DateTime.add(now, -120, :second),
      cancelled_at: now,
      cancelled_by_user_id: driver_id,
      cancellation_reason_code: "rider_unreachable"
    })

    response = post(driver_conn, "/api/rides/999999/driver-cancel", %{}) |> json_response(429)
    assert get_in(response, ["error", "code"]) == "DRIVER_CANCEL_RATE_LIMITED"
  end

  test "POST /api/rides/:ride_id/no-show returns 429 when no-show window exceeded", %{conn: conn} do
    %{auth_conn: driver_conn, user_id: driver_id} = AuthFixtures.authenticate_driver!(conn)
    rider = VerificationFixtures.create_user!()
    category_id = VerificationFixtures.insert_vehicle_category!()
    ensure_driver_profile!(driver_id, category_id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    insert_ride!(%{
      rider_id: rider.id,
      driver_id: driver_id,
      vehicle_category_id: category_id,
      status: "cancelled",
      requested_at: DateTime.add(now, -180, :second),
      cancelled_at: now,
      cancelled_by_user_id: driver_id,
      no_show_marked_at: now,
      cancellation_reason_code: "rider_no_show"
    })

    response = post(driver_conn, "/api/rides/999999/no-show", %{}) |> json_response(429)
    assert get_in(response, ["error", "code"]) == "DRIVER_NO_SHOW_RATE_LIMITED"
  end

  defp insert_ride!(attrs) do
    Repo.insert!(%Ride{
      rider_id: attrs.rider_id,
      driver_id: Map.get(attrs, :driver_id),
      vehicle_category_id: attrs.vehicle_category_id,
      status: attrs.status,
      pickup_lat: Decimal.new("-1.2921000"),
      pickup_lng: Decimal.new("36.8219000"),
      dropoff_lat: Decimal.new("-1.3000000"),
      dropoff_lng: Decimal.new("36.8000000"),
      requested_at: attrs.requested_at,
      cancelled_at: Map.get(attrs, :cancelled_at),
      cancelled_by_user_id: Map.get(attrs, :cancelled_by_user_id),
      no_show_marked_at: Map.get(attrs, :no_show_marked_at),
      cancellation_reason_code: Map.get(attrs, :cancellation_reason_code),
      metadata: %{}
    })
  end

  defp ensure_driver_profile!(driver_id, category_id) do
    case Repo.get(Driver, driver_id) do
      nil ->
        user = Repo.get!(User, driver_id)

        VerificationFixtures.create_driver!(
          user: user,
          vehicle_category_id: category_id,
          subscription_status: "active",
          account_status: "active",
          verification_status: "approved",
          is_available: true
        )

      _driver ->
        :ok
    end
  end
end
