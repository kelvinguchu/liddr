defmodule LiddrWeb.RideMessageRateLimitControllerTest do
  use LiddrWeb.ConnCase, async: false

  alias Liddr.Accounts.Driver
  alias Liddr.Accounts.User
  alias Liddr.Repo
  alias Liddr.Rides.Ride
  alias Liddr.Rides.RideMessage
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

  setup do
    previous_policy = Application.get_env(:liddr, Liddr.Rides.ActionRateLimiter)

    Application.put_env(:liddr, Liddr.Rides.ActionRateLimiter,
      ride_request_window_seconds: 3600,
      ride_request_max_requests: 10,
      rider_cancel_window_seconds: 3600,
      rider_cancel_max_actions: 10,
      driver_cancel_window_seconds: 3600,
      driver_cancel_max_actions: 10,
      driver_no_show_window_seconds: 3600,
      driver_no_show_max_actions: 10,
      message_send_window_seconds: 3600,
      message_send_max_messages: 1
    )

    on_exit(fn ->
      if is_nil(previous_policy) do
        Application.delete_env(:liddr, Liddr.Rides.ActionRateLimiter)
      else
        Application.put_env(:liddr, Liddr.Rides.ActionRateLimiter, previous_policy)
      end
    end)

    :ok
  end

  test "POST /api/rides/:ride_id/messages returns 429 when message window exceeded", %{conn: conn} do
    %{auth_conn: rider_conn, user_id: rider_id} = AuthFixtures.authenticate_rider!(conn)
    %{user_id: driver_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    ensure_driver_profile!(driver_id, category_id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    ride =
      Repo.insert!(%Ride{
        rider_id: rider_id,
        driver_id: driver_id,
        vehicle_category_id: category_id,
        status: "accepted",
        pickup_lat: Decimal.new("-1.2921000"),
        pickup_lng: Decimal.new("36.8219000"),
        dropoff_lat: Decimal.new("-1.3000000"),
        dropoff_lng: Decimal.new("36.8000000"),
        requested_at: DateTime.add(now, -180, :second),
        accepted_at: DateTime.add(now, -120, :second),
        metadata: %{}
      })

    _ =
      Repo.insert!(%RideMessage{
        ride_id: ride.id,
        sender_user_id: rider_id,
        recipient_user_id: driver_id,
        sender_role: "rider",
        message_type: "text",
        body: "Already sent one",
        metadata: %{}
      })

    response =
      post(rider_conn, "/api/rides/#{ride.id}/messages", %{"body" => "Another message"})
      |> json_response(429)

    assert get_in(response, ["error", "code"]) == "RIDE_MESSAGE_RATE_LIMITED"
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
