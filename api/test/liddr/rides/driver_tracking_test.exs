defmodule Liddr.Rides.DriverTrackingTest do
  use Liddr.DataCase, async: false

  alias Liddr.Accounts.Driver
  alias Liddr.Location
  alias Liddr.Location.DriverHotState
  alias Liddr.Location.DriverLocationWriteGate
  alias Liddr.Repo
  alias Liddr.Rides
  alias Liddr.Rides.DriverTracking
  alias Liddr.Rides.Ride
  alias Liddr.Rides.RideEvent
  alias Liddr.Rides.RideNotification
  alias Liddr.Rides.SharedRideGroup
  alias Liddr.Rides.SharedRideMember
  alias Liddr.VerificationFixtures
  alias LiddrWeb.Endpoint
  alias Phoenix.Socket.Broadcast

  @event "driver_location_updated"
  @ping %{"lat" => "-1.2921", "lng" => "36.8219", "bearing" => 90, "speed_kmh" => "35.5"}

  setup do
    :ok = DriverHotState.reset()
    :ok = DriverLocationWriteGate.reset()
    on_exit(fn -> DriverLocationWriteGate.reset() end)
    :ok
  end

  test "a location ping is broadcast to the assigned ride" do
    %{rider: rider, driver: driver, ride: ride} = active_ride!()
    topic = subscribe!(ride)
    ride_id = ride.id

    assert {:ok, _location} = Location.upsert_driver_location(driver.id, @ping)

    assert_receive %Broadcast{topic: ^topic, event: @event, payload: payload}
    assert %{ride_id: ^ride_id, lat: -1.2921, lng: 36.8219} = payload
    assert payload.bearing == 90.0
    assert payload.speed_kmh == 35.5
    assert Enum.sort(payload.visible_user_ids) == Enum.sort([rider.id, driver.id])
  end

  test "invalid bearing and speed values are not sent to riders" do
    %{driver: driver, ride: ride} = active_ride!()
    topic = subscribe!(ride)
    attrs = Map.merge(@ping, %{"bearing" => "<script>", "speed_kmh" => %{"x" => 1}})

    assert {:ok, _location} = Location.upsert_driver_location(driver.id, attrs)

    assert_receive %Broadcast{topic: ^topic, payload: %{bearing: nil, speed_kmh: nil}}
  end

  test "nothing is broadcast once the ride has ended" do
    %{driver: driver, ride: ride} = active_ride!()
    topic = subscribe!(ride)
    ride |> Ecto.Changeset.change(status: "completed", completed_at: now()) |> Repo.update!()

    assert {:ok, _location} = Location.upsert_driver_location(driver.id, @ping)

    refute_receive %Broadcast{topic: ^topic, event: @event}
  end

  test "a driver who no longer owns the ride cannot broadcast to it" do
    %{driver: driver, ride: ride} = active_ride!()
    other_driver = VerificationFixtures.create_user!()

    VerificationFixtures.create_driver!(
      user: other_driver,
      vehicle_category_id: ride.vehicle_category_id
    )

    topic = subscribe!(ride)
    ride |> Ecto.Changeset.change(driver_id: other_driver.id) |> Repo.update!()

    assert {:ok, _location} = Location.upsert_driver_location(driver.id, @ping)

    refute_receive %Broadcast{topic: ^topic, event: @event}
  end

  test "location updates do not create timeline events or notifications" do
    %{driver: driver, ride: ride} = active_ride!()
    ride_id = ride.id

    assert {:ok, _location} = Location.upsert_driver_location(driver.id, @ping)

    assert 0 == Repo.aggregate(from(e in RideEvent, where: e.ride_id == ^ride_id), :count, :id)

    assert 0 ==
             Repo.aggregate(
               from(n in RideNotification, where: n.ride_id == ^ride_id),
               :count,
               :id
             )
  end

  test "shared ride members stop being visible after drop-off" do
    %{rider: rider, driver: driver, ride: ride} = active_ride!("shared")
    dropped_rider = VerificationFixtures.create_user!()
    group = insert_group!(ride)
    insert_member!(group, ride, rider, "picked_up")
    insert_member!(group, ride, dropped_rider, "dropped_off")
    assert {:ok, _location} = Location.upsert_driver_location(driver.id, @ping)

    assert Enum.sort(DriverTracking.visible_user_ids(ride)) == Enum.sort([rider.id, driver.id])
    assert %{lat: -1.2921} = DriverTracking.latest_for_user(ride, rider.id)
    assert is_nil(DriverTracking.latest_for_user(ride, dropped_rider.id))
  end

  test "current trip status returns the latest location only during the ride" do
    %{rider: rider, driver: driver, ride: ride} = active_ride!()
    assert {:ok, _location} = Location.upsert_driver_location(driver.id, @ping)

    assert {:ok, %{current_trip_status: %{driver_location: %{lat: -1.2921}}}} =
             Rides.current_trip_status_for_user(rider.id, ride.id)

    ride |> Ecto.Changeset.change(status: "completed", completed_at: now()) |> Repo.update!()

    assert {:ok, %{current_trip_status: %{driver_location: nil}}} =
             Rides.current_trip_status_for_user(rider.id, ride.id)
  end

  test "users outside the ride cannot read the driver location" do
    %{driver: driver, ride: ride} = active_ride!()
    outsider = VerificationFixtures.create_user!()
    assert {:ok, _location} = Location.upsert_driver_location(driver.id, @ping)

    assert is_nil(DriverTracking.latest_for_user(ride, outsider.id))
  end

  defp subscribe!(ride) do
    topic = "ride:#{ride.id}"
    :ok = Endpoint.subscribe(topic)
    topic
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp active_ride!(product_type \\ "solo") do
    rider = VerificationFixtures.create_user!()
    driver = VerificationFixtures.create_user!()
    category_id = VerificationFixtures.insert_vehicle_category!()

    VerificationFixtures.create_driver!(
      user: driver,
      vehicle_category_id: category_id,
      subscription_status: "active",
      account_status: "active",
      verification_status: "approved",
      is_available: false
    )

    ride =
      Repo.insert!(%Ride{
        rider_id: rider.id,
        driver_id: driver.id,
        vehicle_category_id: category_id,
        status: "accepted",
        product_type: product_type,
        pickup_lat: Decimal.new("-1.2921000"),
        pickup_lng: Decimal.new("36.8219000"),
        dropoff_lat: Decimal.new("-1.3000000"),
        dropoff_lng: Decimal.new("36.8000000"),
        requested_at: now(),
        accepted_at: now(),
        metadata: %{}
      })

    driver_id = driver.id

    Repo.update_all(from(d in Driver, where: d.user_id == ^driver_id),
      set: [current_ride_id: ride.id, dispatch_status: "heading_to_pickup"]
    )

    %{rider: rider, driver: driver, ride: ride}
  end

  defp insert_group!(ride) do
    %SharedRideGroup{}
    |> SharedRideGroup.create_changeset(%{"ride_id" => ride.id, "max_members" => 2})
    |> Repo.insert!()
  end

  defp insert_member!(group, ride, rider, status) do
    %SharedRideMember{}
    |> SharedRideMember.create_changeset(%{
      "group_id" => group.id,
      "ride_id" => ride.id,
      "rider_user_id" => rider.id,
      "status" => status,
      "requested_at" => now()
    })
    |> Repo.insert!()
  end
end
