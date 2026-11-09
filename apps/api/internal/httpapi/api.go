// Package httpapi serves the OpenAPI contract over net/http.
package httpapi

//go:generate go tool oapi-codegen -config ../../oapi-codegen.yaml ../../../../packages/contract/openapi.yaml

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"net/netip"
	"sync/atomic"
	"time"

	"github.com/kelvinguchu/liddr/apps/api/internal/auth"
	"github.com/kelvinguchu/liddr/apps/api/internal/dispatch"
	"github.com/kelvinguchu/liddr/apps/api/internal/disputes"
	"github.com/kelvinguchu/liddr/apps/api/internal/moderation"
	"github.com/kelvinguchu/liddr/apps/api/internal/notifications"
	"github.com/kelvinguchu/liddr/apps/api/internal/ratings"
	"github.com/kelvinguchu/liddr/apps/api/internal/realtime"
	"github.com/kelvinguchu/liddr/apps/api/internal/rides"
	"github.com/kelvinguchu/liddr/apps/api/internal/subscriptions"
	"github.com/kelvinguchu/liddr/apps/api/internal/verification"
)

const readinessTimeout = 2 * time.Second

// Pinger reports whether a dependency is reachable.
type Pinger interface {
	Ping(ctx context.Context) error
}

// Deps holds what the handlers need.
type Deps struct {
	Logger     *slog.Logger
	Database   Pinger
	Categories *rides.Catalog
	Auth       *auth.Service
	Rides      *rides.Service
	Dispatch   *dispatch.Service

	Subscriptions *subscriptions.Service
	Verification  *verification.Service
	Notifications *notifications.Service
	Moderation    *moderation.Service
	Ratings       *ratings.Service
	Disputes      *disputes.Service

	// Realtime and RealtimeOrigins serve live updates. RealtimeBase bounds each
	// socket's life, because a socket outlives the HTTP request that opened it.
	Realtime        *realtime.Hub
	RealtimeBase    context.Context //nolint:containedctx // Server lifetime, not a request.
	RealtimeOrigins []string
	RealtimeJitter  time.Duration

	// MpesaAllowedIPs restricts callbacks when it is not empty.
	MpesaAllowedIPs []netip.Addr

	// OpsAllowedNets restricts staff routes when it is not empty.
	OpsAllowedNets []netip.Prefix

	// TrustedProxyHops is how many proxies in front of this server append to
	// X-Forwarded-For. Zero means clients connect directly.
	TrustedProxyHops int
}

// API implements the generated contract and is the process HTTP handler.
type API struct {
	deps     Deps
	draining atomic.Bool
	handler  http.Handler
}

// New registers every route and returns the API.
func New(deps Deps) *API {
	a := &API{deps: deps}
	mux := http.NewServeMux()
	strict := NewStrictHandlerWithOptions(a, nil, StrictHTTPServerOptions{
		RequestErrorHandlerFunc:  a.requestError,
		ResponseErrorHandlerFunc: a.responseError,
	})
	HandlerWithOptions(strict, StdHTTPServerOptions{
		BaseRouter:       mux,
		Middlewares:      []MiddlewareFunc{a.authenticate},
		ErrorHandlerFunc: a.requestError,
	})
	mux.Handle("GET /v1/realtime", a.protect(http.HandlerFunc(a.openRealtime)))
	a.handler = a.withMiddleware(mux)
	return a
}

func (a *API) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	a.handler.ServeHTTP(w, r)
}

// BeginDrain makes readiness fail so load balancers stop sending new traffic.
func (a *API) BeginDrain() {
	a.draining.Store(true)
}

// GetLiveness reports that the process is running.
func (a *API) GetLiveness(context.Context, GetLivenessRequestObject) (GetLivenessResponseObject, error) {
	return GetLiveness200JSONResponse{Status: Ok}, nil
}

// GetReadiness reports whether this instance should receive traffic.
func (a *API) GetReadiness(ctx context.Context, _ GetReadinessRequestObject) (GetReadinessResponseObject, error) {
	if a.draining.Load() {
		return GetReadiness503JSONResponse{Status: Unavailable}, nil
	}
	ctx, cancel := context.WithTimeout(ctx, readinessTimeout)
	defer cancel()
	if err := a.deps.Database.Ping(ctx); err != nil {
		a.deps.Logger.LogAttrs(ctx, slog.LevelWarn, "readiness check failed", slog.Any("error", err))
		return GetReadiness503JSONResponse{Status: Unavailable}, nil
	}
	return GetReadiness200JSONResponse{Status: Ok}, nil
}

// ListVehicleCategories returns the categories currently offered.
func (a *API) ListVehicleCategories(ctx context.Context, _ ListVehicleCategoriesRequestObject) (ListVehicleCategoriesResponseObject, error) {
	categories, err := a.deps.Categories.ActiveCategories(ctx)
	if err != nil {
		return nil, err
	}
	data := make([]VehicleCategory, len(categories))
	for i, c := range categories {
		data[i] = VehicleCategory{
			Slug:                  c.Slug,
			Label:                 c.Label,
			Capacity:              c.Capacity,
			WeeklySubscriptionKes: c.WeeklySubscriptionKES,
		}
	}
	return ListVehicleCategories200JSONResponse{Data: data}, nil
}

func (a *API) requestError(w http.ResponseWriter, r *http.Request, _ error) {
	writeError(w, r, http.StatusBadRequest, "INVALID_REQUEST", "The request could not be read.")
}

func (a *API) responseError(w http.ResponseWriter, r *http.Request, err error) {
	if p, ok := findProblem(err); ok {
		writeError(w, r, p.status, p.code, p.message)
		return
	}
	if !errors.Is(err, context.Canceled) {
		a.deps.Logger.LogAttrs(r.Context(), slog.LevelError, "request failed",
			slog.String("request_id", requestID(r.Context())),
			slog.String("route", r.Pattern),
			slog.Any("error", err),
		)
	}
	writeError(w, r, http.StatusInternalServerError, "INTERNAL_ERROR", "Something went wrong. Please try again.")
}

func writeError(w http.ResponseWriter, r *http.Request, status int, code, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	// A failed write means the client has gone, and the status is already sent.
	_ = json.NewEncoder(w).Encode(Error{Code: code, Message: message, RequestId: requestID(r.Context())})
}
