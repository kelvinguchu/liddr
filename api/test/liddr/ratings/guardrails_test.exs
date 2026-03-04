defmodule Liddr.Ratings.GuardrailsTest do
  use Liddr.DataCase, async: false

  alias Liddr.Accounts.User
  alias Liddr.Ratings.Guardrails
  alias Liddr.Ratings.Rating
  alias Liddr.Rides.Ride
  alias Liddr.Repo
  alias Liddr.VerificationFixtures

  setup do
    policy_key = Liddr.Ratings.Policy
    previous_policy = Application.get_env(:liddr, policy_key, [])

    Application.put_env(
      :liddr,
      policy_key,
      Keyword.merge(previous_policy,
        enforcement_recent_window_days: 30,
        enforcement_min_recent_ratings: 2
      )
    )

    on_exit(fn -> Application.put_env(:liddr, policy_key, previous_policy) end)
    :ok
  end

  test "enforcement snapshot requires minimum recent attributable ratings" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    rated_user = Repo.insert!(%User{phone: unique_phone()})
    rater_one = Repo.insert!(%User{phone: unique_phone()})
    rater_two = Repo.insert!(%User{phone: unique_phone()})
    rater_old = Repo.insert!(%User{phone: unique_phone()})
    category_id = VerificationFixtures.insert_vehicle_category!()

    ride_one = create_completed_ride!(rated_user.id, category_id, now)
    ride_two = create_completed_ride!(rated_user.id, category_id, now)
    ride_three = create_completed_ride!(rated_user.id, category_id, now)

    _ =
      Repo.insert!(%Rating{
        ride_id: ride_one.id,
        rated_by_user_id: rater_one.id,
        rated_user_id: rated_user.id,
        score: 5,
        include_in_score: true,
        submitted_at: now,
        metadata: %{}
      })

    _ =
      Repo.insert!(%Rating{
        ride_id: ride_two.id,
        rated_by_user_id: rater_two.id,
        rated_user_id: rated_user.id,
        score: 4,
        include_in_score: true,
        submitted_at: DateTime.add(now, -86_400, :second),
        metadata: %{}
      })

    _ =
      Repo.insert!(%Rating{
        ride_id: ride_three.id,
        rated_by_user_id: rater_old.id,
        rated_user_id: rated_user.id,
        score: 1,
        include_in_score: false,
        nullified_at: now,
        nullified_by_user_id: rater_one.id,
        nullification_reason_code: "ops_nullified",
        submitted_at: DateTime.add(now, -50 * 86_400, :second),
        metadata: %{}
      })

    snapshot = Guardrails.enforcement_snapshot_for_user(rated_user.id, now)

    assert snapshot.rated_user_id == rated_user.id
    assert snapshot.recent_attributable_ratings == 2
    assert snapshot.minimum_required == 2
    assert snapshot.ready? == true
  end

  defp unique_phone do
    suffix =
      System.unique_integer([:positive])
      |> Integer.to_string()
      |> String.pad_leading(8, "0")
      |> String.slice(-8, 8)

    "07" <> suffix
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
end
