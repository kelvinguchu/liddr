defmodule Liddr.Moderation.EnforcementLifecycleTest do
  use Liddr.DataCase, async: false

  import Ecto.Query

  alias Liddr.Accounts.Driver
  alias Liddr.Accounts.User
  alias Liddr.Moderation
  alias Liddr.Moderation.UserEnforcement
  alias Liddr.Repo
  alias Liddr.Verification.DriverActivityEvent
  alias Liddr.VerificationFixtures

  test "expire_due_temporary_suspensions restores rider to active when no active restrictions remain" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    target = Repo.insert!(%User{phone: VerificationFixtures.unique_phone()})
    actor = Repo.insert!(%User{phone: VerificationFixtures.unique_phone()})

    {:ok, enforcement} =
      Moderation.apply_enforcement(%{
        "user_id" => target.id,
        "actor_user_id" => actor.id,
        "action" => "temporary_suspension",
        "reason_code" => "safety_review",
        "ends_at" => DateTime.to_iso8601(DateTime.add(now, 3600, :second))
      })

    mark_enforcement_due!(enforcement.id, now)

    {:ok, results} = Moderation.expire_due_temporary_suspensions(%{now: now, limit: 10})

    assert Enum.any?(results, fn result ->
             result.enforcement_id == enforcement.id and result.status == "expired"
           end)

    updated_enforcement = Repo.get!(UserEnforcement, enforcement.id)
    assert updated_enforcement.status == "expired"
    assert not is_nil(updated_enforcement.lifted_at)

    updated_user = Repo.get!(User, target.id)
    assert updated_user.account_status == "active"
    assert is_nil(updated_user.account_status_reason_code)
    assert is_nil(updated_user.account_restricted_until)
  end

  test "expire_due_temporary_suspensions keeps user suspended when another active suspension exists" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    target = Repo.insert!(%User{phone: VerificationFixtures.unique_phone()})
    actor = Repo.insert!(%User{phone: VerificationFixtures.unique_phone()})

    {:ok, due_enforcement} =
      Moderation.apply_enforcement(%{
        "user_id" => target.id,
        "actor_user_id" => actor.id,
        "action" => "temporary_suspension",
        "reason_code" => "first_case",
        "ends_at" => DateTime.to_iso8601(DateTime.add(now, 3600, :second))
      })

    {:ok, active_enforcement} =
      Moderation.apply_enforcement(%{
        "user_id" => target.id,
        "actor_user_id" => actor.id,
        "action" => "temporary_suspension",
        "reason_code" => "second_case",
        "ends_at" => DateTime.to_iso8601(DateTime.add(now, 7200, :second))
      })

    mark_enforcement_due!(due_enforcement.id, now)

    {:ok, _results} = Moderation.expire_due_temporary_suspensions(%{now: now, limit: 10})

    expired = Repo.get!(UserEnforcement, due_enforcement.id)
    still_active = Repo.get!(UserEnforcement, active_enforcement.id)
    updated_user = Repo.get!(User, target.id)

    assert expired.status == "expired"
    assert still_active.status == "active"
    assert updated_user.account_status == "suspended"
    assert updated_user.account_status_reason_code == "second_case"
    assert DateTime.compare(updated_user.account_restricted_until, still_active.ends_at) == :eq
  end

  test "expire_due_temporary_suspensions restores driver state and keeps availability offline" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    actor = Repo.insert!(%User{phone: VerificationFixtures.unique_phone()})
    target = Repo.insert!(%User{phone: VerificationFixtures.unique_phone()})
    category_id = VerificationFixtures.insert_vehicle_category!()

    _driver =
      VerificationFixtures.create_driver!(
        user: target,
        vehicle_category_id: category_id,
        account_status: "active",
        verification_status: "approved",
        subscription_status: "active",
        is_available: true
      )

    {:ok, enforcement} =
      Moderation.apply_enforcement(%{
        "user_id" => target.id,
        "actor_user_id" => actor.id,
        "action" => "temporary_suspension",
        "reason_code" => "driver_review",
        "ends_at" => DateTime.to_iso8601(DateTime.add(now, 3600, :second))
      })

    suspended_driver = Repo.get!(Driver, target.id)
    assert suspended_driver.account_status == "suspended"
    assert suspended_driver.is_available == false

    mark_enforcement_due!(enforcement.id, now)
    {:ok, _results} = Moderation.expire_due_temporary_suspensions(%{now: now, limit: 10})

    restored_driver = Repo.get!(Driver, target.id)
    updated_user = Repo.get!(User, target.id)

    assert restored_driver.account_status == "active"
    assert restored_driver.is_available == false
    assert is_nil(restored_driver.suspended_at)
    assert updated_user.account_status == "active"

    events_count =
      Repo.aggregate(
        from(event in DriverActivityEvent, where: event.driver_id == ^target.id),
        :count,
        :id
      )

    assert events_count == 2
  end

  defp mark_enforcement_due!(enforcement_id, now) do
    starts_at = DateTime.add(now, -3600, :second)
    ends_at = DateTime.add(now, -60, :second)

    {count, _} =
      Repo.update_all(
        from(ue in UserEnforcement, where: ue.id == ^enforcement_id),
        set: [starts_at: starts_at, ends_at: ends_at, updated_at: now]
      )

    assert count == 1
  end
end
