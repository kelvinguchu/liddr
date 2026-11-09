package dispatch

import "cmp"

const (
	distanceWeight     = 0.7
	ratingWeight       = 0.3
	distanceDecayM     = 1_000.0
	rankBucketM        = 250
	newDriverMinRated  = 10
	newDriverNeutral   = 0.7
	minRatingCenti     = 100.0
	ratingRangeCenti   = 400.0
	maxRatingCentiRank = 500.0
)

// ratingScore puts a rating on a 0 to 1 scale. A driver with too few ratings
// gets a neutral score, so being new is neither a penalty nor an advantage.
func ratingScore(centi *int32, count int32) float64 {
	if centi == nil || count < newDriverMinRated {
		return newDriverNeutral
	}
	return (min(max(float64(*centi), minRatingCenti), maxRatingCentiRank) - minRatingCenti) / ratingRangeCenti
}

func (c candidate) score() float64 {
	return distanceWeight/(1+float64(c.distanceM)/distanceDecayM) + ratingWeight*c.rating
}

// compareCandidates groups drivers into 250m bands, so that distance decides
// first and rating only separates drivers who are about equally close.
func compareCandidates(a, b candidate) int {
	return cmp.Or(
		cmp.Compare(a.distanceM/rankBucketM, b.distanceM/rankBucketM),
		cmp.Compare(b.score(), a.score()),
		cmp.Compare(a.distanceM, b.distanceM),
	)
}
