defmodule Liddr.Ratings.ScoringTest do
  use Liddr.DataCase, async: false

  alias Liddr.Ratings.Scoring

  test "single low rating after many five stars has limited impact with smoothing" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    ratings =
      Enum.map(1..10, fn _ ->
        %{score: 5, submitted_at: now}
      end) ++ [%{score: 1, submitted_at: now}]

    stats = Scoring.aggregate_stats(ratings, now)

    assert Decimal.compare(stats.rating_score, Decimal.new("4.70")) in [:eq, :gt]
    assert stats.rating_count == 11
  end
end
