package dispatch

import "testing"

func TestRanking(t *testing.T) {
	good, poor := new(int32(490)), new(int32(310))
	cases := []struct {
		name         string
		first, other candidate
	}{
		{"a much closer driver wins despite rating", candidate{distanceM: 100, rating: ratingScore(poor, 50)}, candidate{distanceM: 1500, rating: ratingScore(good, 50)}},
		{"within a band the better rated driver wins", candidate{distanceM: 240, rating: ratingScore(good, 50)}, candidate{distanceM: 10, rating: ratingScore(poor, 50)}},
		{"a new driver beats a poorly rated one nearby", candidate{distanceM: 200, rating: ratingScore(nil, 0)}, candidate{distanceM: 150, rating: ratingScore(poor, 50)}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if compareCandidates(tc.first, tc.other) >= 0 {
				t.Errorf("%+v should rank before %+v", tc.first, tc.other)
			}
		})
	}
}

func TestRatingScoreIgnoresThinHistory(t *testing.T) {
	if got := ratingScore(new(int32(100)), 3); got != newDriverNeutral {
		t.Errorf("score = %v, want neutral", got)
	}
}
