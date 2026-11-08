defmodule Liddr.Ratings.EnforcementSignalsTest do
  use Liddr.DataCase, async: false

  import Ecto.Query

  alias Liddr.Accounts.User
  alias Liddr.Accounts.UserRole
  alias Liddr.Moderation.Report
  alias Liddr.Ratings.EnforcementSignals
  alias Liddr.Ratings.Rating
  alias Liddr.Repo
  alias Liddr.Rides.Ride
  alias Liddr.VerificationFixtures

  setup do
    policy_key = Liddr.Ratings.Policy
    previous_policy = Application.get_env(:liddr, policy_key, [])

    Application.put_env(
      :liddr,
      policy_key,
      Keyword.merge(previous_policy,
        enforcement_recent_window_days: 30,
        enforcement_min_recent_ratings: 1
      )
    )

    on_exit(fn -> Application.put_env(:liddr, policy_key, previous_policy) end)
    :ok
  end

  test "creates one system moderation report for sustained low driver rating and deduplicates" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    category_id = VerificationFixtures.insert_vehicle_category!()
    driver_user = Repo.insert!(%User{phone: unique_phone()})
    rater_user = Repo.insert!(%User{phone: unique_phone()})

    _ =
      Repo.insert!(%UserRole{
        user_id: driver_user.id,
        role: "driver",
        granted_at: now
      })

    _ = insert_recent_rating!(driver_user.id, rater_user.id, category_id, now)

    stats = %{rating_score: Decimal.new("3.40"), rating_count: 50}

    assert {:ok, :signal_created} =
             EnforcementSignals.maybe_emit_low_rating_signal(driver_user.id, stats, now)

    assert {:ok, :signal_already_open} =
             EnforcementSignals.maybe_emit_low_rating_signal(driver_user.id, stats, now)

    reports =
      Repo.all(
        from r in Report,
          where:
            r.reported_user_id == ^driver_user.id and
              r.context_reference == ^"rating_signal:driver_low_3_5_over_50:#{driver_user.id}"
      )

    assert length(reports) == 1
    assert hd(reports).source == "system"
  end

  test "does not create moderation report when guardrail volume is not met" do
    policy_key = Liddr.Ratings.Policy
    previous_policy = Application.get_env(:liddr, policy_key, [])

    Application.put_env(
      :liddr,
      policy_key,
      Keyword.merge(previous_policy, enforcement_min_recent_ratings: 5)
    )

    on_exit(fn -> Application.put_env(:liddr, policy_key, previous_policy) end)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    category_id = VerificationFixtures.insert_vehicle_category!()
    driver_user = Repo.insert!(%User{phone: unique_phone()})
    rater_user = Repo.insert!(%User{phone: unique_phone()})

    _ =
      Repo.insert!(%UserRole{
        user_id: driver_user.id,
        role: "driver",
        granted_at: now
      })

    _ = insert_recent_rating!(driver_user.id, rater_user.id, category_id, now)

    stats = %{rating_score: Decimal.new("3.20"), rating_count: 60}

    assert {:ok, :insufficient_rating_volume} =
             EnforcementSignals.maybe_emit_low_rating_signal(driver_user.id, stats, now)

    assert Repo.aggregate(Report, :count, :id) == 0
  end

  defp insert_recent_rating!(rated_user_id, rated_by_user_id, category_id, now) do
    ride = create_completed_ride!(rated_user_id, category_id, now)

    Repo.insert!(%Rating{
      ride_id: ride.id,
      rated_by_user_id: rated_by_user_id,
      rated_user_id: rated_user_id,
      score: 4,
      include_in_score: true,
      submitted_at: now,
      metadata: %{"source" => "test"}
    })
  end

  defp create_completed_ride!(rider_id, category_id, now) do
    Repo.insert!(%Ride{
      rider_id: rider_id,
      vehicle_category_id: category_id,
      status: "completed",
      pickup_lat: Decimal.new("-1.2921000"),
      pickup_lng: Decimal.new("36.8219000"),
      dropoff_lat: Decimal.new("-1.3000000"),
      dropoff_lng: Decimal.new("36.8000000"),
      requested_at: DateTime.add(now, -3_600, :second),
      completed_at: DateTime.add(now, -1_800, :second),
      metadata: %{}
    })
  end

  defp unique_phone do
    suffix =
      System.unique_integer([:positive])
      |> Integer.to_string()
      |> String.pad_leading(8, "0")
      |> String.slice(-8, 8)

    "07" <> suffix
  end
end
