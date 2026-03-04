defmodule Liddr.Rides.NotificationRetryTest do
  use Liddr.DataCase, async: false

  @behaviour Liddr.Rides.PushClient

  import Ecto.Query

  alias Liddr.Accounts.User
  alias Liddr.Repo
  alias Liddr.Rides.NotificationRetry
  alias Liddr.Rides.Notifications
  alias Liddr.Rides.Ride
  alias Liddr.Rides.RideNotification
  alias Liddr.VerificationFixtures

  setup do
    previous_push_client = Application.get_env(:liddr, :ride_push_client)
    Application.put_env(:liddr, :ride_push_client, __MODULE__)
    Process.delete(:ride_push_result)

    on_exit(fn ->
      restore_env(:ride_push_client, previous_push_client)
      Process.delete(:ride_push_result)
    end)

    :ok
  end

  test "run marks pending notifications as sent when push delivery succeeds" do
    ride = create_ride_with_participants!()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    _ =
      Notifications.queue_realtime_event!(
        ride,
        "driver_arriving",
        %{"ride_id" => ride.id},
        now
      )

    assert {:ok, result} =
             NotificationRetry.run(%{
               "limit" => 10,
               "max_attempts" => 3,
               "retry_interval_seconds" => 1
             })

    assert result.processed == 2
    assert result.sent == 2
    assert result.failed == 0
    assert result.retry_scheduled == 0

    statuses =
      Repo.all(
        from n in RideNotification,
          where: n.ride_id == ^ride.id and n.event_type == "driver_arriving",
          select: {n.push_status, n.attempt_count}
      )

    assert length(statuses) == 2

    assert Enum.all?(statuses, fn {push_status, attempt_count} ->
             push_status == "sent" and attempt_count == 1
           end)

    ride_id = ride.id
    assert_receive {:ride_push_attempt, %{ride_id: ^ride_id}}
  end

  test "run keeps notification pending until max attempts are reached and then fails it" do
    Process.put(:ride_push_result, {:error, :upstream_unavailable})
    ride = create_ride_with_participants!()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    _ =
      Notifications.queue_realtime_event!(
        ride,
        "driver_arrived",
        %{"ride_id" => ride.id},
        now
      )

    assert {:ok, first_result} =
             NotificationRetry.run(%{
               "limit" => 10,
               "max_attempts" => 2,
               "retry_interval_seconds" => 1
             })

    assert first_result.processed == 2
    assert first_result.retry_scheduled == 2
    assert first_result.failed == 0

    Process.put(:ride_push_result, {:error, :upstream_unavailable})

    {2, _} =
      Repo.update_all(
        from(n in RideNotification,
          where: n.ride_id == ^ride.id and n.event_type == "driver_arrived"
        ),
        set: [last_attempt_at: DateTime.add(now, -5, :second), updated_at: now]
      )

    assert {:ok, second_result} =
             NotificationRetry.run(%{
               "limit" => 10,
               "max_attempts" => 2,
               "retry_interval_seconds" => 1
             })

    assert second_result.processed == 2
    assert second_result.failed == 2

    statuses =
      Repo.all(
        from n in RideNotification,
          where: n.ride_id == ^ride.id and n.event_type == "driver_arrived",
          select: {n.push_status, n.attempt_count}
      )

    assert Enum.all?(statuses, fn {push_status, attempt_count} ->
             push_status == "failed" and attempt_count == 2
           end)
  end

  @impl Liddr.Rides.PushClient
  def send_ride_notification(payload) do
    send(self(), {:ride_push_attempt, payload})
    Process.get(:ride_push_result, :ok)
  end

  defp create_ride_with_participants! do
    category_id = VerificationFixtures.insert_vehicle_category!()
    rider = Repo.insert!(%User{phone: VerificationFixtures.unique_phone()})
    driver_user = Repo.insert!(%User{phone: VerificationFixtures.unique_phone()})

    _driver_profile =
      VerificationFixtures.create_driver!(
        user: driver_user,
        vehicle_category_id: category_id,
        account_status: "active",
        verification_status: "approved",
        subscription_status: "active",
        is_available: true
      )

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert!(%Ride{
      rider_id: rider.id,
      driver_id: driver_user.id,
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

  defp restore_env(key, nil), do: Application.delete_env(:liddr, key)
  defp restore_env(key, value), do: Application.put_env(:liddr, key, value)
end
