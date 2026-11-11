// Package geo holds coordinate types and distance calculations.
package geo

import "math"

const (
	earthRadiusM = 6_371_000.0
	metresPerDeg = 111_000.0

	// minCosLat stops longitude spans exploding near the poles.
	minCosLat = 0.1
)

// Point is a position in decimal degrees.
type Point struct {
	Lat float64
	Lng float64
}

// Valid reports whether p is a real position.
func (p Point) Valid() bool {
	return p.Lat >= -90 && p.Lat <= 90 && p.Lng >= -180 && p.Lng <= 180 &&
		!math.IsNaN(p.Lat) && !math.IsNaN(p.Lng)
}

// InKenya reports whether p falls inside Kenya's bounding box.
func (p Point) InKenya() bool {
	return p.Lat >= -4.9 && p.Lat <= 5.1 && p.Lng >= 33.9 && p.Lng <= 41.95
}

// Box is a latitude and longitude range.
type Box struct {
	MinLat, MaxLat, MinLng, MaxLng float64
}

// BoxAround returns a box containing every point within radiusM of p.
func BoxAround(p Point, radiusM float64) Box {
	latDelta := radiusM / metresPerDeg
	lngDelta := radiusM / (metresPerDeg * math.Max(math.Cos(radians(p.Lat)), minCosLat))
	return Box{MinLat: p.Lat - latDelta, MaxLat: p.Lat + latDelta, MinLng: p.Lng - lngDelta, MaxLng: p.Lng + lngDelta}
}

// DistanceM returns the great-circle distance between two points in metres.
func DistanceM(a, b Point) float64 {
	dLat := radians(b.Lat - a.Lat)
	dLng := radians(b.Lng - a.Lng)
	h := math.Pow(math.Sin(dLat/2), 2) + math.Cos(radians(a.Lat))*math.Cos(radians(b.Lat))*math.Pow(math.Sin(dLng/2), 2)
	return 2 * earthRadiusM * math.Atan2(math.Sqrt(h), math.Sqrt(1-h))
}

func radians(degrees float64) float64 {
	return degrees * math.Pi / 180
}
