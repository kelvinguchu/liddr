// Package maps calls the Google Routes API.
package maps

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/kelvinguchu/liddr/apps/api/internal/geo"
)

const (
	routesPath      = "/directions/v2:computeRoutes"
	fieldMask       = "routes.distanceMeters,routes.duration,routes.polyline.encodedPolyline"
	requestTimeout  = 7 * time.Second
	maxResponseSize = 2 << 20
)

// ErrNoRoute reports that the provider returned nothing usable.
var ErrNoRoute = errors.New("no usable route returned")

// RouteRequest describes the trip to route.
type RouteRequest struct {
	Origin            geo.Point
	Destination       geo.Point
	TravelMode        string
	RoutingPreference string
}

// Route is the provider's answer.
type Route struct {
	DistanceM int32
	DurationS int32
	Polyline  string
}

// Client is a Google Routes API client.
type Client struct {
	baseURL string
	apiKey  string
	http    *http.Client
}

// NewClient returns a Client for the API at baseURL.
func NewClient(baseURL, apiKey string) *Client {
	return &Client{
		baseURL: strings.TrimRight(baseURL, "/"),
		apiKey:  apiKey,
		http:    &http.Client{Timeout: requestTimeout},
	}
}

type waypoint struct {
	Location struct {
		LatLng struct {
			Latitude  float64 `json:"latitude"`
			Longitude float64 `json:"longitude"`
		} `json:"latLng"`
	} `json:"location"`
}

func toWaypoint(p geo.Point) waypoint {
	var w waypoint
	w.Location.LatLng.Latitude = p.Lat
	w.Location.LatLng.Longitude = p.Lng
	return w
}

// ComputeRoute asks Google for the best route. Errors never include coordinates
// or the response body, which can echo them.
func (c *Client) ComputeRoute(ctx context.Context, req RouteRequest) (Route, error) {
	payload, err := json.Marshal(map[string]any{
		"origin":                   toWaypoint(req.Origin),
		"destination":              toWaypoint(req.Destination),
		"travelMode":               req.TravelMode,
		"routingPreference":        req.RoutingPreference,
		"computeAlternativeRoutes": false,
		"units":                    "METRIC",
		"languageCode":             "en-US",
	})
	if err != nil {
		return Route{}, fmt.Errorf("encode route request: %w", err)
	}
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+routesPath, bytes.NewReader(payload))
	if err != nil {
		return Route{}, errors.New("build route request")
	}
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("X-Goog-Api-Key", c.apiKey)
	httpReq.Header.Set("X-Goog-FieldMask", fieldMask)

	resp, err := c.http.Do(httpReq)
	if err != nil {
		return Route{}, fmt.Errorf("call routes api: %w", err)
	}
	defer func() {
		// The response has been fully handled by the time this runs.
		_ = resp.Body.Close()
	}()
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return Route{}, fmt.Errorf("routes api returned status %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxResponseSize))
	if err != nil {
		return Route{}, fmt.Errorf("read routes response: %w", err)
	}
	return parseRoute(body)
}

func parseRoute(body []byte) (Route, error) {
	var parsed struct {
		Routes []struct {
			// Google omits distanceMeters when it is zero.
			DistanceMeters int32  `json:"distanceMeters"`
			Duration       string `json:"duration"`
			Polyline       struct {
				EncodedPolyline string `json:"encodedPolyline"`
			} `json:"polyline"`
		} `json:"routes"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil || len(parsed.Routes) == 0 {
		return Route{}, ErrNoRoute
	}
	route := parsed.Routes[0]
	if route.DistanceMeters < 0 {
		return Route{}, ErrNoRoute
	}
	seconds, err := parseDuration(route.Duration)
	if err != nil {
		return Route{}, err
	}
	return Route{DistanceM: route.DistanceMeters, DurationS: seconds, Polyline: route.Polyline.EncodedPolyline}, nil
}

func parseDuration(value string) (int32, error) {
	number, found := strings.CutSuffix(value, "s")
	if !found {
		return 0, ErrNoRoute
	}
	seconds, err := strconv.ParseFloat(number, 64)
	if err != nil || seconds < 0 || seconds > math.MaxInt32 {
		return 0, ErrNoRoute
	}
	return int32(math.Ceil(seconds)), nil
}
