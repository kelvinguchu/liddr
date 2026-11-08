package httpapi

import (
	"errors"
	"net/http"

	"github.com/kelvinguchu/liddr/apps/api/internal/dispatch"
	"github.com/kelvinguchu/liddr/apps/api/internal/payments"
	"github.com/kelvinguchu/liddr/apps/api/internal/rides"
	"github.com/kelvinguchu/liddr/apps/api/internal/subscriptions"
)

// problem is how a domain error appears to a client.
type problem struct {
	err     error
	status  int
	code    string
	message string
}

// problems maps domain errors to responses. Handlers return these errors
// unchanged, and anything not listed becomes a generic 500.
var problems = []problem{
	{rides.ErrCategoryNotFound, http.StatusBadRequest, "CATEGORY_NOT_AVAILABLE", "That vehicle type is not available."},
	{rides.ErrOutsideServiceArea, http.StatusBadRequest, "OUTSIDE_SERVICE_AREA", "Liddr is not available at that location."},
	{rides.ErrRouteUnavailable, http.StatusServiceUnavailable, "ROUTE_UNAVAILABLE", "We could not price this trip. Please try again."},
	{rides.ErrRateLimited, http.StatusTooManyRequests, "RATE_LIMITED", "Too many requests. Please wait and try again."},
	{rides.ErrQuoteNotFound, http.StatusNotFound, "QUOTE_NOT_FOUND", "That price is no longer available."},
	{rides.ErrQuoteExpired, http.StatusConflict, "QUOTE_EXPIRED", "That price has expired. Please get a new one."},
	{rides.ErrActiveRideExists, http.StatusConflict, "ACTIVE_RIDE_EXISTS", "You already have a ride in progress."},
	{rides.ErrRideNotFound, http.StatusNotFound, "RIDE_NOT_FOUND", "That ride could not be found."},
	{rides.ErrInvalidTransition, http.StatusConflict, "INVALID_RIDE_STATE", "That is not possible at this stage of the ride."},
	{rides.ErrInvalidReason, http.StatusBadRequest, "INVALID_REASON", "Choose a valid reason."},
	{rides.ErrInvalidPaymentMode, http.StatusBadRequest, "INVALID_PAYMENT_MODE", "Choose how the rider paid."},
	{rides.ErrLocationUnknown, http.StatusConflict, "LOCATION_UNKNOWN", "We cannot confirm your location. Check your GPS and try again."},
	{rides.ErrTooFarFromPickup, http.StatusConflict, "TOO_FAR_FROM_PICKUP", "You are too far from the pickup point."},
	{rides.ErrTooFarFromDropoff, http.StatusConflict, "TOO_FAR_FROM_DROPOFF", "You are too far from the destination."},
	{rides.ErrNoShowTooEarly, http.StatusConflict, "NO_SHOW_TOO_EARLY", "Please wait the full five minutes first."},
	{dispatch.ErrProfileMissing, http.StatusNotFound, "DRIVER_PROFILE_MISSING", "Finish setting up your driver profile first."},
	{dispatch.ErrCategoryLocked, http.StatusConflict, "CATEGORY_LOCKED", "Your vehicle type cannot change after approval."},
	{dispatch.ErrNotVerified, http.StatusForbidden, "DRIVER_NOT_VERIFIED", "Your documents have not been approved yet."},
	{dispatch.ErrSubscriptionNeeded, http.StatusForbidden, "SUBSCRIPTION_REQUIRED", "Renew your weekly subscription to go online."},
	{dispatch.ErrDriverBusy, http.StatusConflict, "DRIVER_BUSY", "Finish your current ride first."},
	{dispatch.ErrDriverOffline, http.StatusConflict, "DRIVER_OFFLINE", "Go online to share your location."},
	{dispatch.ErrInvalidLocation, http.StatusBadRequest, "INVALID_LOCATION", "That location is not valid."},
	{dispatch.ErrOfferNotFound, http.StatusNotFound, "OFFER_NOT_FOUND", "That offer could not be found."},
	{dispatch.ErrOfferClosed, http.StatusConflict, "OFFER_CLOSED", "That offer is no longer available."},
	{subscriptions.ErrProfileMissing, http.StatusNotFound, "DRIVER_PROFILE_MISSING", "Finish setting up your driver profile first."},
	{subscriptions.ErrNotVerified, http.StatusForbidden, "DRIVER_NOT_VERIFIED", "Your documents have not been approved yet."},
	{subscriptions.ErrAlreadyActive, http.StatusConflict, "ALREADY_ACTIVE", "This week is already paid."},
	{subscriptions.ErrPaymentPending, http.StatusConflict, "PAYMENT_PENDING", "Check your phone. A payment is already waiting for your PIN."},
	{subscriptions.ErrRateLimited, http.StatusTooManyRequests, "RATE_LIMITED", "Too many attempts. Please wait and try again."},
	{subscriptions.ErrPaymentRefused, http.StatusBadGateway, "PAYMENT_REFUSED", "M-Pesa could not start this payment. Please try again."},
	{subscriptions.ErrCallbackRefused, http.StatusUnauthorized, "UNAUTHORIZED", "Not authorized."},
	{payments.ErrInvalidCallback, http.StatusBadRequest, "INVALID_CALLBACK", "The callback could not be read."},
}

func findProblem(err error) (problem, bool) {
	for _, p := range problems {
		if errors.Is(err, p.err) {
			return p, true
		}
	}
	return problem{}, false
}
