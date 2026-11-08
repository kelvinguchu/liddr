defmodule LiddrWeb.RideOpsControllerTest do
  use LiddrWeb.ConnCase, async: false

  alias Liddr.Accounts.User
  alias Liddr.Repo
  alias Liddr.Rides.Events
  alias Liddr.Rides.Notifications
  alias Liddr.Rides.PickupWatchdog
  alias Liddr.Rides.Ride
  alias Liddr.Security.Redaction
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

  setup do
    previous_security_mode = System.get_env("SECURITY_MODE")
    previous_ops_ip_allowlist = System.get_env("OPS_IP_ALLOWLIST")

    System.put_env("SECURITY_MODE", "observe")
    System.delete_env("OPS_IP_ALLOWLIST")

    on_exit(fn ->
      restore_env("SECURITY_MODE", previous_security_mode)
      restore_env("OPS_IP_ALLOWLIST", previous_ops_ip_allowlist)
    end)

    :ok
  end

  test "GET /api/ops/rides/integrity/users/:user_id requires auth", %{conn: conn} do
    conn = get(conn, "/api/ops/rides/integrity/users/1")
    assert %{"error" => %{"code" => "AUTH_REQUIRED"}} = json_response(conn, 401)
  end

  test "GET /api/ops/rides/integrity/users/:user_id requires ops totp enrollment", %{conn: _conn} do
    %{auth_conn: ops_conn} =
      AuthFixtures.authenticate_ops!("ops-rides-no-totp@example.com", enroll_totp: false)

    conn = get(ops_conn, "/api/ops/rides/integrity/users/1")

    assert %{"error" => %{"code" => "OPS_MFA_ENROLLMENT_REQUIRED"}} = json_response(conn, 403)
  end

  test "GET /api/ops/rides/integrity/users/:user_id returns counters and prepay mode", %{
    conn: _conn
  } do
    %{auth_conn: ops_conn} = AuthFixtures.authenticate_ops!("ops-rides-integrity@example.com")
    target_user = Repo.insert!(%User{phone: VerificationFixtures.unique_phone()})
    category_id = VerificationFixtures.insert_vehicle_category!()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    set_prepay_only!(target_user.id, DateTime.add(now, 3600, :second))
    seed_chargeable_cancel!(target_user.id, category_id, "rider", "rider_changed_mind", now, 1)
    seed_chargeable_cancel!(target_user.id, category_id, "rider", "driver_not_moving", now, 2)
    seed_chargeable_cancel!(target_user.id, category_id, "driver", "vehicle_issue", now, 3)

    conn = get(ops_conn, "/api/ops/rides/integrity/users/#{target_user.id}?recent_limit=2")

    assert %{
             "data" => %{
               "user" => %{"id" => user_id, "ride_booking_mode" => "prepay_only"},
               "prepay_mode" => %{"active" => true, "mode" => "prepay_only"},
               "counters" => %{
                 "rider_chargeable_events_7d" => 2,
                 "driver_chargeable_events_7d" => 1
               },
               "recent_chargeable_events" => recent_events
             }
           } = json_response(conn, 200)

    assert user_id == target_user.id
    assert length(recent_events) == 2
  end

  test "POST /api/ops/rides/integrity/reconcile-prepay-modes validates limit", %{conn: _conn} do
    %{auth_conn: ops_conn} =
      AuthFixtures.authenticate_ops!("ops-rides-integrity-limit@example.com")

    ops_conn = AuthFixtures.with_step_up!(ops_conn)

    conn = post(ops_conn, "/api/ops/rides/integrity/reconcile-prepay-modes", %{"limit" => "0"})

    assert %{"error" => %{"code" => "INVALID_PREPAY_RECONCILIATION_LIMIT"}} =
             json_response(conn, 422)
  end

  test "POST /api/ops/rides/integrity/reconcile-prepay-modes reconciles due users", %{conn: _conn} do
    %{auth_conn: ops_conn} =
      AuthFixtures.authenticate_ops!("ops-rides-integrity-reconcile@example.com")

    ops_conn = AuthFixtures.with_step_up!(ops_conn)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    due_user = Repo.insert!(%User{phone: VerificationFixtures.unique_phone()})
    active_user = Repo.insert!(%User{phone: VerificationFixtures.unique_phone()})

    set_prepay_only!(due_user.id, DateTime.add(now, -60, :second))
    set_prepay_only!(active_user.id, DateTime.add(now, 3600, :second))

    conn =
      post(ops_conn, "/api/ops/rides/integrity/reconcile-prepay-modes", %{
        "limit" => 10
      })

    assert %{
             "data" => %{
               "processed" => 1,
               "reconciled" => 1,
               "results" => [%{"user_id" => user_id}]
             }
           } = json_response(conn, 200)

    assert user_id == due_user.id

    updated_due_user = Repo.get!(User, due_user.id)
    updated_active_user = Repo.get!(User, active_user.id)

    assert updated_due_user.ride_booking_mode == "normal"
    assert is_nil(updated_due_user.ride_booking_mode_until)
    assert updated_active_user.ride_booking_mode == "prepay_only"
  end

  test "GET /api/ops/rides/pickup-watchdog/summary returns recent auto actions", %{conn: _conn} do
    %{auth_conn: ops_conn} = AuthFixtures.authenticate_ops!("ops-pickup-watchdog@example.com")
    category_id = VerificationFixtures.insert_vehicle_category!()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    rider = Repo.insert!(%User{phone: VerificationFixtures.unique_phone()})
    driver = Repo.insert!(%User{phone: VerificationFixtures.unique_phone()})

    _driver_profile =
      VerificationFixtures.create_driver!(
        user: driver,
        vehicle_category_id: category_id,
        account_status: "active",
        verification_status: "approved",
        subscription_status: "active",
        is_available: true
      )

    ride =
      %Ride{}
      |> Ride.create_changeset(%{
        "rider_id" => rider.id,
        "driver_id" => driver.id,
        "vehicle_category_id" => category_id,
        "status" => "accepted",
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "requested_at" => DateTime.add(now, -800, :second),
        "accepted_at" => DateTime.add(now, -700, :second),
        "metadata" => %{}
      })
      |> Repo.insert!()

    recent_reassign_at = DateTime.add(now, -120, :second)
    recent_cancel_at = DateTime.add(now, -60, :second)
    old_action_at = DateTime.add(now, -4_000, :second)

    {:ok, _} =
      Events.record_event(ride.id, PickupWatchdog.auto_reassign_event_type(), recent_reassign_at,
        actor_user_id: rider.id,
        payload: %{
          "action_reason_code" => "pickup_timeout_auto_reassign",
          "pickup_health" => %{
            "recommendation_reason_code" => "driver_moving_away",
            "flags" => %{"driver_moving_away" => true},
            "signals" => %{"accepted_elapsed_seconds" => 700},
            "timeouts" => %{"auto_reassign_due" => true}
          }
        }
      )

    {:ok, _} =
      Events.record_event(ride.id, PickupWatchdog.auto_cancel_event_type(), recent_cancel_at,
        actor_user_id: rider.id,
        payload: %{
          "action_reason_code" => "driver_not_moving",
          "pickup_health" => %{
            "recommendation_reason_code" => "driver_no_progress",
            "flags" => %{"driver_no_progress" => true},
            "signals" => %{"accepted_elapsed_seconds" => 900},
            "timeouts" => %{"auto_cancel_due" => true}
          }
        }
      )

    {:ok, _} =
      Events.record_event(ride.id, PickupWatchdog.auto_reassign_event_type(), old_action_at,
        actor_user_id: rider.id,
        payload: %{"action_reason_code" => "pickup_timeout_auto_reassign"}
      )

    since = DateTime.add(now, -300, :second) |> DateTime.to_iso8601()

    conn =
      get(
        ops_conn,
        "/api/ops/rides/pickup-watchdog/summary?since=#{URI.encode_www_form(since)}&limit=10"
      )

    assert %{
             "data" => %{
               "counts" => %{
                 "total" => 2,
                 "auto_reassigned" => 1,
                 "auto_cancelled" => 1
               },
               "recent_actions" => actions
             }
           } = json_response(conn, 200)

    assert length(actions) == 2
    assert Enum.all?(actions, &(&1["ride_id"] == ride.id))
  end

  test "GET /api/ops/rides/pickup-watchdog/summary validates since and limit", %{conn: _conn} do
    %{auth_conn: ops_conn} =
      AuthFixtures.authenticate_ops!("ops-pickup-watchdog-invalid@example.com")

    bad_since =
      get(ops_conn, "/api/ops/rides/pickup-watchdog/summary?since=not-a-date&limit=10")

    assert %{"error" => %{"code" => "INVALID_SINCE"}} = json_response(bad_since, 422)

    bad_limit =
      get(
        ops_conn,
        "/api/ops/rides/pickup-watchdog/summary?since=2026-03-03T00:00:00Z&limit=10000"
      )

    assert %{"error" => %{"code" => "INVALID_PICKUP_WATCHDOG_LIMIT"}} =
             json_response(bad_limit, 422)
  end

  test "GET /api/ops/rides/:ride_id/notifications returns ride notification rows", %{conn: _conn} do
    %{auth_conn: ops_conn} = AuthFixtures.authenticate_ops!("ops-ride-notifications@example.com")
    category_id = VerificationFixtures.insert_vehicle_category!()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    rider = Repo.insert!(%User{phone: VerificationFixtures.unique_phone()})
    driver = Repo.insert!(%User{phone: VerificationFixtures.unique_phone()})

    _driver_profile =
      VerificationFixtures.create_driver!(
        user: driver,
        vehicle_category_id: category_id,
        account_status: "active",
        verification_status: "approved",
        subscription_status: "active",
        is_available: true
      )

    ride =
      create_accepted_ride!(rider.id, driver.id, category_id, now)

    _ =
      Notifications.queue_realtime_event!(
        ride,
        "driver_arrived",
        %{
          "ride_id" => ride.id,
          "reason_code" => "driver_arrived",
          "phone" => "254725799783",
          "pickup_lat" => "-1.2921",
          "message" => "driver is outside"
        },
        now
      )

    conn = get(ops_conn, "/api/ops/rides/#{ride.id}/notifications?limit=10")

    assert %{"data" => %{"notifications" => rows}} = json_response(conn, 200)
    assert length(rows) == 2
    assert Enum.all?(rows, &(&1["ride_id"] == ride.id))
    assert Enum.all?(rows, &(&1["event_type"] == "driver_arrived"))

    assert Enum.all?(rows, fn row ->
             payload = row["payload"] || %{}

             payload["phone"] in [nil, Redaction.mask_phone("254725799783")] and
               payload["pickup_lat"] in [nil, "[redacted]"] and
               payload["message"] in [nil, "[redacted]"]
           end)
  end

  test "GET /api/ops/rides/:ride_id/notifications validates ride_id", %{conn: _conn} do
    %{auth_conn: ops_conn} =
      AuthFixtures.authenticate_ops!("ops-ride-notifications-invalid@example.com")

    conn = get(ops_conn, "/api/ops/rides/invalid/notifications")

    assert %{"error" => %{"code" => "INVALID_RIDE_ID"}} = json_response(conn, 422)
  end

  defp seed_chargeable_cancel!(target_user_id, category_id, subject_role, reason_code, now, idx) do
    requested_at = DateTime.add(now, -(idx * 240), :second)
    cancelled_at = DateTime.add(requested_at, 120, :second)

    %Ride{}
    |> Ride.create_changeset(%{
      "rider_id" => target_user_id,
      "vehicle_category_id" => category_id,
      "status" => "cancelled",
      "pickup_lat" => "-1.2921",
      "pickup_lng" => "36.8219",
      "dropoff_lat" => "-1.3000",
      "dropoff_lng" => "36.8000",
      "requested_at" => requested_at,
      "cancelled_at" => cancelled_at,
      "cancellation_reason_code" => reason_code,
      "cancelled_by_user_id" => target_user_id,
      "metadata" => %{
        "integrity" => %{
          "policy_version" => "ride_integrity_v1",
          "subject_role" => subject_role,
          "subject_user_id" => target_user_id,
          "chargeable" => true
        }
      }
    })
    |> Repo.insert!()
  end

  defp set_prepay_only!(user_id, mode_until) do
    user = Repo.get!(User, user_id)

    user
    |> User.ride_booking_mode_changeset(%{
      "ride_booking_mode" => "prepay_only",
      "ride_booking_mode_until" => mode_until
    })
    |> Repo.update!()
  end

  defp create_accepted_ride!(rider_id, driver_id, category_id, now) do
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

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
