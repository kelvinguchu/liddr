defmodule Liddr.Rides.Integrity.ModeLifecycleWorkerTest do
  use Liddr.DataCase, async: false

  alias Liddr.Accounts.User
  alias Liddr.Repo
  alias Liddr.Rides.Integrity.ModeLifecycleWorker
  alias Liddr.VerificationFixtures

  test "worker expires due prepay-only rider modes" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    due_user = Repo.insert!(%User{phone: VerificationFixtures.unique_phone()})
    active_user = Repo.insert!(%User{phone: VerificationFixtures.unique_phone()})

    set_prepay_only!(due_user.id, DateTime.add(now, -120, :second))
    set_prepay_only!(active_user.id, DateTime.add(now, 3600, :second))

    assert :ok = ModeLifecycleWorker.perform(%Oban.Job{args: %{"limit" => 10}})

    updated_due_user = Repo.get!(User, due_user.id)
    updated_active_user = Repo.get!(User, active_user.id)

    assert updated_due_user.ride_booking_mode == "normal"
    assert is_nil(updated_due_user.ride_booking_mode_until)
    assert updated_active_user.ride_booking_mode == "prepay_only"
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
end
