defmodule LiddrWeb.RideNotificationControllerTest do
  use LiddrWeb.ConnCase, async: false

  import Ecto.Query

  alias Liddr.Accounts.User
  alias Liddr.Repo
  alias Liddr.Rides.Notifications
  alias Liddr.Rides.Realtime
  alias Liddr.Rides.Ride
  alias Liddr.Rides.RideNotification
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

  test "list returns sticky trip-state notifications for rider and driver", %{conn: conn} do
    %{auth_conn: rider_conn, user_id: rider_user_id} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    _ = create_driver_profile!(driver_user_id, category_id)
    ride = create_accepted_ride!(rider_user_id, driver_user_id, category_id)

    Realtime.broadcast_driver_arriving(ride)

    assert %{"data" => %{"notifications" => rider_notifications}} =
             get(rider_conn, "/api/notifications?limit=20")
             |> json_response(200)

    assert Enum.any?(rider_notifications, fn row ->
             row["ride_id"] == ride.id and row["event_type"] == "driver_arriving" and
               row["socket_status"] == "sent"
           end)

    assert %{"data" => %{"notifications" => driver_notifications}} =
             get(driver_conn, "/api/notifications?limit=20")
             |> json_response(200)

    assert Enum.any?(driver_notifications, fn row ->
             row["ride_id"] == ride.id and row["event_type"] == "driver_arriving" and
               row["socket_status"] == "sent"
           end)
  end

  test "ack marks notification as acked and hides it from default list", %{conn: conn} do
    %{auth_conn: rider_conn, user_id: rider_user_id} = AuthFixtures.authenticate_rider!(conn)
    %{user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    _ = create_driver_profile!(driver_user_id, category_id)
    ride = create_accepted_ride!(rider_user_id, driver_user_id, category_id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    _ =
      Notifications.queue_realtime_event!(
        ride,
        "driver_arrived",
        %{"ride_id" => ride.id},
        now
      )

    notification =
      Repo.one!(
        from n in RideNotification,
          where:
            n.ride_id == ^ride.id and n.recipient_user_id == ^rider_user_id and
              n.event_type == "driver_arrived",
          order_by: [desc: n.id],
          limit: 1
      )

    assert %{"data" => %{"notification" => %{"id" => id, "socket_status" => "acked"}}} =
             post(rider_conn, "/api/notifications/#{notification.id}/ack", %{})
             |> json_response(200)

    assert id == notification.id

    assert %{"data" => %{"notifications" => rows}} =
             get(rider_conn, "/api/notifications?limit=20")
             |> json_response(200)

    refute Enum.any?(rows, &(&1["id"] == notification.id))

    assert %{"data" => %{"notifications" => rows_with_acked}} =
             get(rider_conn, "/api/notifications?limit=20&include_acked=true")
             |> json_response(200)

    assert Enum.any?(rows_with_acked, fn row ->
             row["id"] == notification.id and row["socket_status"] == "acked"
           end)
  end

  test "summary returns unread, critical and latest notification timestamp", %{conn: conn} do
    %{auth_conn: rider_conn, user_id: rider_user_id} = AuthFixtures.authenticate_rider!(conn)
    %{user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    _ = create_driver_profile!(driver_user_id, category_id)
    ride = create_accepted_ride!(rider_user_id, driver_user_id, category_id)
    first_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    second_at = DateTime.add(first_at, 1, :second)

    _ =
      Notifications.queue_event_for_user!(
        ride.id,
        rider_user_id,
        "driver_arrived",
        %{"ride_id" => ride.id},
        first_at
      )

    _ =
      Notifications.queue_event_for_user!(
        ride.id,
        rider_user_id,
        "ride_cancelled",
        %{"ride_id" => ride.id},
        second_at
      )

    notification =
      Repo.one!(
        from n in RideNotification,
          where:
            n.ride_id == ^ride.id and n.recipient_user_id == ^rider_user_id and
              n.event_type == "driver_arrived",
          order_by: [desc: n.id],
          limit: 1
      )

    _ = post(rider_conn, "/api/notifications/#{notification.id}/ack", %{}) |> json_response(200)

    assert %{
             "data" => %{
               "unread_count" => 1,
               "critical_count" => 1,
               "latest_notification_at" => latest_notification_at
             }
           } =
             get(rider_conn, "/api/notifications/summary")
             |> json_response(200)

    assert latest_notification_at == DateTime.to_iso8601(second_at)
  end

  defp create_accepted_ride!(rider_id, driver_id, category_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert!(%Ride{
      rider_id: rider_id,
      driver_id: driver_id,
      vehicle_category_id: category_id,
      status: "accepted",
      pickup_lat: Decimal.new("-1.2921000"),
      pickup_lng: Decimal.new("36.8219000"),
      dropoff_lat: Decimal.new("-1.3000000"),
      dropoff_lng: Decimal.new("36.8000000"),
      requested_at: DateTime.add(now, -120, :second),
      accepted_at: DateTime.add(now, -60, :second),
      metadata: %{}
    })
  end

  defp create_driver_profile!(driver_user_id, category_id) do
    user = Repo.get!(User, driver_user_id)

    VerificationFixtures.create_driver!(
      user: user,
      vehicle_category_id: category_id,
      account_status: "active",
      verification_status: "approved",
      subscription_status: "active",
      is_available: true
    )
  end
end
