defmodule LiddrWeb.RideCancellationReplayTest do
  use Liddr.DataCase, async: true

  import Ecto.Query
  import Phoenix.ChannelTest

  alias Liddr.Accounts.User
  alias Liddr.Repo
  alias Liddr.Rides
  alias Liddr.Rides.Ride
  alias Liddr.Rides.RideNotification
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures
  alias LiddrWeb.RideChannel
  alias LiddrWeb.UserSocket

  @endpoint LiddrWeb.Endpoint

  test "driver sees rider cancellation on replay after reconnect" do
    %{user_id: rider_id} = AuthFixtures.authenticate_with_role!("rider")

    %{access_token: driver_token, user_id: driver_id} =
      AuthFixtures.authenticate_with_role!("driver")

    category_id = VerificationFixtures.insert_vehicle_category!()
    _driver = create_driver_profile!(driver_id, category_id)
    ride = create_accepted_ride!(rider_id, driver_id, category_id)

    assert {:ok, cancelled_ride} =
             Rides.rider_cancel_ride(rider_id, ride.id, %{"reason" => "rider_changed_mind"})

    assert cancelled_ride.status == "cancelled"

    notification =
      Repo.one!(
        from n in RideNotification,
          where:
            n.ride_id == ^ride.id and n.event_type == "ride_cancelled" and
              n.recipient_user_id == ^driver_id
      )

    assert notification.socket_status == "sent"

    {:ok, socket} = connect(UserSocket, %{"token" => driver_token})

    assert {:ok, %{events: events}, _joined_socket} =
             subscribe_and_join(socket, RideChannel, "ride:#{ride.id}", %{})

    assert Enum.any?(events, fn event ->
             payload_value(event, :event_type) == "ride_cancelled" and
               payload_value(payload_value(event, :payload), :reason_code) == "rider_changed_mind"
           end)
  end

  defp payload_value(payload, key) when is_map(payload),
    do: Map.get(payload, key) || Map.get(payload, Atom.to_string(key))

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
      requested_at: now,
      accepted_at: now,
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
