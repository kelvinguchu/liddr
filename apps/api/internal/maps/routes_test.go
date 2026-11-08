package maps

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/google/go-cmp/cmp"

	"github.com/kelvinguchu/liddr/apps/api/internal/geo"
)

var nairobiTrip = RouteRequest{
	Origin:            geo.Point{Lat: -1.2921, Lng: 36.8219},
	Destination:       geo.Point{Lat: -1.3000, Lng: 36.8000},
	TravelMode:        "TWO_WHEELER",
	RoutingPreference: "TRAFFIC_AWARE",
}

func TestComputeRouteRequestShape(t *testing.T) {
	var path, key, mask string
	var body map[string]any
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path, key, mask = r.URL.Path, r.Header.Get("X-Goog-Api-Key"), r.Header.Get("X-Goog-FieldMask")
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		_, _ = fmt.Fprint(w, `{"routes":[{"distanceMeters":5000,"duration":"899.2s","polyline":{"encodedPolyline":"abc"}}]}`)
	}))
	defer server.Close()

	got, err := NewClient(server.URL+"/", "secret-key").ComputeRoute(t.Context(), nairobiTrip)
	if err != nil {
		t.Fatalf("ComputeRoute: %v", err)
	}
	if diff := cmp.Diff(got, Route{DistanceM: 5000, DurationS: 900, Polyline: "abc"}); diff != "" {
		t.Errorf("route mismatch (-got +want):\n%s", diff)
	}
	if path != "/directions/v2:computeRoutes" || key != "secret-key" || !strings.Contains(mask, "routes.duration") {
		t.Errorf("path=%q key=%q mask=%q", path, key, mask)
	}
	if body["travelMode"] != "TWO_WHEELER" || body["routingPreference"] != "TRAFFIC_AWARE" {
		t.Errorf("body = %v", body)
	}
}

func TestComputeRouteResponses(t *testing.T) {
	tests := []struct {
		name   string
		status int
		body   string
		want   Route
		fails  bool
	}{
		{name: "zero distance omitted", status: 200, body: `{"routes":[{"duration":"0s"}]}`, want: Route{}},
		{name: "no routes", status: 200, body: `{"routes":[]}`, fails: true},
		{name: "empty object", status: 200, body: `{}`, fails: true},
		{name: "missing duration", status: 200, body: `{"routes":[{"distanceMeters":10}]}`, fails: true},
		{name: "bad duration", status: 200, body: `{"routes":[{"duration":"soon"}]}`, fails: true},
		{name: "negative duration", status: 200, body: `{"routes":[{"duration":"-3s"}]}`, fails: true},
		{name: "not json", status: 200, body: `<html>`, fails: true},
		{name: "server error", status: 500, body: `{}`, fails: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(tt.status)
				_, _ = fmt.Fprint(w, tt.body)
			}))
			defer server.Close()

			got, err := NewClient(server.URL, "key").ComputeRoute(t.Context(), nairobiTrip)
			if tt.fails {
				if err == nil {
					t.Fatalf("ComputeRoute = %v, want error", got)
				}
				return
			}
			if err != nil {
				t.Fatalf("ComputeRoute: %v", err)
			}
			if diff := cmp.Diff(got, tt.want); diff != "" {
				t.Errorf("route mismatch (-got +want):\n%s", diff)
			}
		})
	}
}

func TestErrorsNeverLeakCoordinates(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = fmt.Fprint(w, `{"error":{"message":"bad point -1.2921"}}`)
	}))
	defer server.Close()

	_, err := NewClient(server.URL, "key").ComputeRoute(t.Context(), nairobiTrip)
	if err == nil || strings.Contains(err.Error(), "1.2921") {
		t.Errorf("error = %v", err)
	}
	if errors.Is(err, ErrNoRoute) {
		t.Errorf("a provider failure must not read as no route: %v", err)
	}
}
