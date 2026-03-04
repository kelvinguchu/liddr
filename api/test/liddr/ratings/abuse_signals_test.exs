defmodule Liddr.Ratings.AbuseSignalsTest do
  use Liddr.DataCase, async: false

  import Ecto.Query

  alias Liddr.Accounts.User
  alias Liddr.Accounts.UserRole
  alias Liddr.Moderation.Report
  alias Liddr.Ratings.AbuseSignals
  alias Liddr.Ratings.Rating
  alias Liddr.Repo
  alias Liddr.Rides.Ride
  alias Liddr.VerificationFixtures

  test "emits five-star velocity abuse signal report" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    category_id = VerificationFixtures.insert_vehicle_category!()
    rated_user = Repo.insert!(%User{phone: unique_phone()})

    _ =
      Repo.insert!(%UserRole{
        user_id: rated_user.id,
        role: "driver",
        granted_at: now
      })

    ratings =
      Enum.map(1..10, fn _ ->
        rater_user = Repo.insert!(%User{phone: unique_phone()})
        insert_rating!(rater_user.id, rated_user.id, category_id, now, 5)
      end)

    last_rating = List.last(ratings)

    assert {:ok, :processed} = AbuseSignals.maybe_emit_abuse_signals(last_rating, now)

    assert Repo.exists?(
             from r in Report,
               where:
                 r.reported_user_id == ^rated_user.id and
                   r.context_reference == ^"rating_abuse:five_star_velocity_1h:#{rated_user.id}" and
                   r.source == "system"
           )
  end

  test "emits pair concentration abuse signal report" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    category_id = VerificationFixtures.insert_vehicle_category!()
    rated_user = Repo.insert!(%User{phone: unique_phone()})
    repeated_rater = Repo.insert!(%User{phone: unique_phone()})

    _ =
      Repo.insert!(%UserRole{
        user_id: rated_user.id,
        role: "driver",
        granted_at: now
      })

    _ =
      Enum.map(1..5, fn day_offset ->
        inserted_at = DateTime.add(now, -day_offset * 86_400, :second)
        insert_rating!(repeated_rater.id, rated_user.id, category_id, inserted_at, 5)
      end)

    other_rater = Repo.insert!(%User{phone: unique_phone()})

    _ =
      insert_rating!(
        other_rater.id,
        rated_user.id,
        category_id,
        DateTime.add(now, -2 * 86_400, :second),
        5
      )

    trigger_rating =
      insert_rating!(
        repeated_rater.id,
        rated_user.id,
        category_id,
        DateTime.add(now, -600, :second),
        5
      )

    assert {:ok, :processed} = AbuseSignals.maybe_emit_abuse_signals(trigger_rating, now)

    assert Repo.exists?(
             from r in Report,
               where:
                 r.reported_user_id == ^rated_user.id and
                   r.context_reference ==
                     ^"rating_abuse:pair_concentration_30d:#{rated_user.id}:#{repeated_rater.id}" and
                   r.source == "system"
           )
  end

  defp insert_rating!(rated_by_user_id, rated_user_id, category_id, submitted_at, score) do
    ride =
      Repo.insert!(%Ride{
        rider_id: rated_by_user_id,
        vehicle_category_id: category_id,
        status: "completed",
        pickup_lat: Decimal.new("-1.2921000"),
        pickup_lng: Decimal.new("36.8219000"),
        dropoff_lat: Decimal.new("-1.3000000"),
        dropoff_lng: Decimal.new("36.8000000"),
        requested_at: DateTime.add(submitted_at, -1_800, :second),
        completed_at: submitted_at,
        metadata: %{}
      })

    Repo.insert!(%Rating{
      ride_id: ride.id,
      rated_by_user_id: rated_by_user_id,
      rated_user_id: rated_user_id,
      score: score,
      include_in_score: true,
      submitted_at: submitted_at,
      metadata: %{"source" => "test"}
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
