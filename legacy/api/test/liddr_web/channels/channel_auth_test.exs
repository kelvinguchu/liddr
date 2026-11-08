defmodule LiddrWeb.ChannelAuthTest do
  use Liddr.DataCase, async: true

  import Phoenix.ChannelTest

  alias Liddr.Accounts.User
  alias Liddr.Repo
  alias Liddr.Rides.Ride
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures
  alias LiddrWeb.DriverChannel
  alias LiddrWeb.RideChannel
  alias LiddrWeb.UserSocket

  @endpoint LiddrWeb.Endpoint

  test "driver can join own driver topic only" do
    %{access_token: token, user_id: driver_id} = AuthFixtures.authenticate_with_role!("driver")
    {:ok, socket} = connect(UserSocket, %{"token" => token})

    assert {:ok, %{driver_id: ^driver_id}, _socket} =
             subscribe_and_join(socket, DriverChannel, "driver:#{driver_id}")

    assert {:error, %{reason: "forbidden"}} =
             subscribe_and_join(socket, DriverChannel, "driver:#{driver_id + 1}")
  end

  test "non-driver cannot join driver topic" do
    %{access_token: token, user_id: rider_id} = AuthFixtures.authenticate_with_role!("rider")
    {:ok, socket} = connect(UserSocket, %{"token" => token})

    assert {:error, %{reason: "forbidden"}} =
             subscribe_and_join(socket, DriverChannel, "driver:#{rider_id}")
  end

  test "rider and assigned driver can join ride topic; unrelated user is rejected" do
    %{access_token: rider_token, user_id: rider_id} =
      AuthFixtures.authenticate_with_role!("rider")

    %{access_token: driver_token, user_id: driver_id} =
      AuthFixtures.authenticate_with_role!("driver")

    %{access_token: stranger_token} = AuthFixtures.authenticate_with_role!("rider")

    category_id = VerificationFixtures.insert_vehicle_category!()
    _driver = create_eligible_driver_profile!(driver_id, category_id)
    ride = create_accepted_ride!(rider_id, driver_id, category_id)
    ride_id = ride.id

    {:ok, rider_socket} = connect(UserSocket, %{"token" => rider_token})
    {:ok, driver_socket} = connect(UserSocket, %{"token" => driver_token})
    {:ok, stranger_socket} = connect(UserSocket, %{"token" => stranger_token})

    assert {:ok, %{ride_id: ^ride_id}, _socket} =
             subscribe_and_join(rider_socket, RideChannel, "ride:#{ride_id}")

    assert {:ok, %{ride_id: ^ride_id}, _socket} =
             subscribe_and_join(driver_socket, RideChannel, "ride:#{ride_id}")

    assert {:error, %{reason: "forbidden"}} =
             subscribe_and_join(stranger_socket, RideChannel, "ride:#{ride_id}")
  end

  defp create_eligible_driver_profile!(user_id, category_id) do
    user = Repo.get!(User, user_id)

    VerificationFixtures.create_driver!(
      user: user,
      vehicle_category_id: category_id,
      account_status: "active",
      verification_status: "approved",
      subscription_status: "active",
      is_available: true
    )
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
      requested_at: now,
      accepted_at: now,
      metadata: %{}
    })
  end
end
