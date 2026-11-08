defmodule LiddrWeb.RideChannelReplayTest do
  use Liddr.DataCase, async: true

  import Ecto.Query
  import Phoenix.ChannelTest

  alias Liddr.Accounts.User
  alias Liddr.Repo
  alias Liddr.Rides.Events
  alias Liddr.Rides.Ride
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures
  alias LiddrWeb.RideChannel
  alias LiddrWeb.UserSocket

  @endpoint LiddrWeb.Endpoint

  test "join returns replay snapshot for ride participants" do
    %{access_token: rider_token, user_id: rider_id} =
      AuthFixtures.authenticate_with_role!("rider")

    %{user_id: driver_id} = AuthFixtures.authenticate_with_role!("driver")
    category_id = VerificationFixtures.insert_vehicle_category!()
    _driver = create_driver_profile!(driver_id, category_id)
    ride = create_accepted_ride!(rider_id, driver_id, category_id)
    ride_id = ride.id
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, _} =
      Events.record_event(ride.id, "ride_requested", now,
        actor_user_id: rider_id,
        payload: %{"offers_count" => 1}
      )

    {:ok, _} =
      Events.record_event(ride.id, "ride_accepted", DateTime.add(now, 1, :second),
        actor_user_id: driver_id,
        payload: %{"offer_id" => 11}
      )

    {:ok, socket} = connect(UserSocket, %{"token" => rider_token})

    assert {:ok, %{ride_id: ^ride_id, ride: ride_payload, events: events, next_since: next_since},
            _socket} =
             subscribe_and_join(socket, RideChannel, "ride:#{ride_id}", %{"limit" => 10})

    assert payload_value(ride_payload, :id) == ride_id
    assert length(events) == 2

    assert Enum.map(events, &payload_value(&1, :event_type)) == [
             "ride_requested",
             "ride_accepted"
           ]

    assert match?(%DateTime{}, next_since) or is_binary(next_since)
  end

  test "join with since replays only new events" do
    %{access_token: rider_token, user_id: rider_id} =
      AuthFixtures.authenticate_with_role!("rider")

    %{user_id: driver_id} = AuthFixtures.authenticate_with_role!("driver")
    category_id = VerificationFixtures.insert_vehicle_category!()
    _driver = create_driver_profile!(driver_id, category_id)
    ride = create_accepted_ride!(rider_id, driver_id, category_id)
    ride_id = ride.id
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, _} = Events.record_event(ride.id, "ride_requested", now, actor_user_id: rider_id)

    {:ok, _} =
      Events.record_event(ride.id, "ride_accepted", DateTime.add(now, 1, :second),
        actor_user_id: driver_id
      )

    {:ok, first_socket} = connect(UserSocket, %{"token" => rider_token})

    assert {:ok, %{events: [_], next_since: cursor}, _} =
             subscribe_and_join(first_socket, RideChannel, "ride:#{ride_id}", %{"limit" => 1})

    {:ok, second_socket} = connect(UserSocket, %{"token" => rider_token})

    assert {:ok, %{events: [event], next_since: _}, _} =
             subscribe_and_join(second_socket, RideChannel, "ride:#{ride_id}", %{
               "since" => normalize_cursor(cursor)
             })

    assert payload_value(event, :event_type) == "ride_accepted"
  end

  test "timeline.sync returns incremental events without rejoin" do
    %{access_token: rider_token, user_id: rider_id} =
      AuthFixtures.authenticate_with_role!("rider")

    %{user_id: driver_id} = AuthFixtures.authenticate_with_role!("driver")
    category_id = VerificationFixtures.insert_vehicle_category!()
    _driver = create_driver_profile!(driver_id, category_id)
    ride = create_accepted_ride!(rider_id, driver_id, category_id)
    ride_id = ride.id
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, _} = Events.record_event(ride.id, "ride_requested", now, actor_user_id: rider_id)

    {:ok, socket} = connect(UserSocket, %{"token" => rider_token})

    assert {:ok, %{events: [_], next_since: cursor}, joined_socket} =
             subscribe_and_join(socket, RideChannel, "ride:#{ride_id}", %{"limit" => 1})

    {:ok, _} =
      Events.record_event(ride.id, "driver_arriving", DateTime.add(now, 1, :second),
        actor_user_id: driver_id
      )

    ref = push(joined_socket, "timeline.sync", %{"since" => normalize_cursor(cursor)})
    assert_reply ref, :ok, %{ride_id: ^ride_id, events: [event], next_since: _}, 1_000
    assert payload_value(event, :event_type) == "driver_arriving"
  end

  test "timeline.sync rejects when user no longer has ride access" do
    %{access_token: rider_token, user_id: rider_id} =
      AuthFixtures.authenticate_with_role!("rider")

    %{user_id: driver_id} = AuthFixtures.authenticate_with_role!("driver")
    %{user_id: other_rider_id} = AuthFixtures.authenticate_with_role!("rider")
    category_id = VerificationFixtures.insert_vehicle_category!()
    _driver = create_driver_profile!(driver_id, category_id)
    ride = create_accepted_ride!(rider_id, driver_id, category_id)
    ride_id = ride.id

    {:ok, socket} = connect(UserSocket, %{"token" => rider_token})

    assert {:ok, _payload, joined_socket} =
             subscribe_and_join(socket, RideChannel, "ride:#{ride_id}", %{})

    _ = Repo.update_all(from(r in Ride, where: r.id == ^ride_id), set: [rider_id: other_rider_id])

    ref = push(joined_socket, "timeline.sync", %{})
    assert_reply ref, :error, %{reason: "forbidden"}, 1_000
  end

  test "driver location is pushed to allowed viewers without exposing the audience" do
    %{access_token: token, user_id: rider_id, ride_id: ride_id} = joined_ride_fixture()
    {:ok, socket} = connect(UserSocket, %{"token" => token})

    assert {:ok, %{driver_location: nil}, _socket} =
             subscribe_and_join(socket, RideChannel, "ride:#{ride_id}", %{})

    LiddrWeb.Endpoint.broadcast("ride:#{ride_id}", "driver_location_updated", %{
      ride_id: ride_id,
      lat: -1.29,
      lng: 36.82,
      visible_user_ids: [rider_id]
    })

    assert_push "driver_location_updated", payload, 2_000
    assert payload.lat == -1.29
    refute Map.has_key?(payload, :visible_user_ids)
  end

  test "driver location is not pushed to subscribers outside the audience" do
    %{access_token: token, ride_id: ride_id} = joined_ride_fixture()
    {:ok, socket} = connect(UserSocket, %{"token" => token})

    assert {:ok, _reply, joined_socket} =
             subscribe_and_join(socket, RideChannel, "ride:#{ride_id}", %{})

    LiddrWeb.Endpoint.broadcast("ride:#{ride_id}", "driver_location_updated", %{
      ride_id: ride_id,
      lat: -1.29,
      lng: 36.82,
      visible_user_ids: []
    })

    assert_receive %Phoenix.Socket.Broadcast{event: "driver_location_updated"}
    _ = :sys.get_state(joined_socket.channel_pid)
    refute_push "driver_location_updated", _payload, 0
  end

  defp joined_ride_fixture do
    %{access_token: token, user_id: rider_id} = AuthFixtures.authenticate_with_role!("rider")
    %{user_id: driver_id} = AuthFixtures.authenticate_with_role!("driver")
    category_id = VerificationFixtures.insert_vehicle_category!()
    _driver = create_driver_profile!(driver_id, category_id)
    ride = create_accepted_ride!(rider_id, driver_id, category_id)
    %{access_token: token, user_id: rider_id, ride_id: ride.id}
  end

  defp normalize_cursor(%DateTime{} = cursor), do: DateTime.to_iso8601(cursor)
  defp normalize_cursor(cursor) when is_binary(cursor), do: cursor
  defp normalize_cursor(_cursor), do: nil

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
