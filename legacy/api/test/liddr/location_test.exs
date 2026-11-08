defmodule Liddr.LocationTest do
  use Liddr.DataCase, async: false

  alias Liddr.Accounts.Driver
  alias Liddr.Location
  alias Liddr.Location.DriverHotState
  alias Liddr.Location.DriverLocation
  alias Liddr.Location.DriverLocationWriteGate
  alias Liddr.Repo
  alias Liddr.VerificationFixtures

  setup do
    previous_gate_config = Application.get_env(:liddr, DriverLocationWriteGate)

    on_exit(fn ->
      if is_nil(previous_gate_config) do
        Application.delete_env(:liddr, DriverLocationWriteGate)
      else
        Application.put_env(:liddr, DriverLocationWriteGate, previous_gate_config)
      end

      :ok = DriverLocationWriteGate.reset()
    end)

    :ok = DriverLocationWriteGate.reset()
    :ok = DriverHotState.reset()
    :ok
  end

  test "upsert_driver_location does not rewrite last_seen_at when it is still fresh" do
    last_seen_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    category_id = VerificationFixtures.insert_vehicle_category!()
    user = VerificationFixtures.create_user!()

    driver =
      VerificationFixtures.create_driver!(
        user: user,
        vehicle_category_id: category_id,
        subscription_status: "active",
        account_status: "active",
        verification_status: "approved",
        is_available: true
      )

    driver
    |> Driver.create_changeset(%{"last_seen_at" => last_seen_at})
    |> Repo.update!()

    assert {:ok, _location} =
             Location.upsert_driver_location(user.id, %{"lat" => "-1.2921", "lng" => "36.8219"})

    assert Repo.get!(Driver, user.id).last_seen_at == last_seen_at
  end

  test "upsert_driver_location coalesces repeated db writes within the persist window" do
    Application.put_env(:liddr, DriverLocationWriteGate,
      min_persist_interval_ms: 10_000,
      force_persist_distance_m: 10_000.0
    )

    category_id = VerificationFixtures.insert_vehicle_category!()
    user = VerificationFixtures.create_user!()

    _driver =
      VerificationFixtures.create_driver!(
        user: user,
        vehicle_category_id: category_id,
        subscription_status: "active",
        account_status: "active",
        verification_status: "approved",
        is_available: true
      )

    assert {:ok, first_location} =
             Location.upsert_driver_location(user.id, %{"lat" => "-1.2921", "lng" => "36.8219"})

    persisted = Repo.get!(DriverLocation, user.id)

    assert {:ok, second_location} =
             Location.upsert_driver_location(user.id, %{"lat" => "-1.29215", "lng" => "36.82195"})

    persisted_after = Repo.get!(DriverLocation, user.id)

    assert persisted_after.captured_at == persisted.captured_at
    assert persisted_after.lat == persisted.lat
    assert persisted_after.lng == persisted.lng
    assert second_location.captured_at != first_location.captured_at
    assert second_location.lat != persisted_after.lat
    assert second_location.lng != persisted_after.lng
  end
end
