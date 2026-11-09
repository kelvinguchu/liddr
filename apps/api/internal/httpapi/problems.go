package httpapi

import (
	"errors"
	"net/http"

	"github.com/kelvinguchu/liddr/apps/api/internal/auth"
	"github.com/kelvinguchu/liddr/apps/api/internal/dispatch"
	"github.com/kelvinguchu/liddr/apps/api/internal/notifications"
	"github.com/kelvinguchu/liddr/apps/api/internal/payments"
	"github.com/kelvinguchu/liddr/apps/api/internal/rides"
	"github.com/kelvinguchu/liddr/apps/api/internal/subscriptions"
	"github.com/kelvinguchu/liddr/apps/api/internal/verification"
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
	{errMFAEnrolmentRequired, http.StatusForbidden, "MFA_ENROLMENT_REQUIRED", "Set up your authenticator app first."},
	{errAddressNotAllowed, http.StatusForbidden, "ADDRESS_NOT_ALLOWED", "Staff tools cannot be used from this network."},
	{auth.ErrStepUpRequired, http.StatusForbidden, "STEP_UP_REQUIRED", "Confirm with your authenticator code to continue."},
	{auth.ErrFreshSignInRequired, http.StatusForbidden, "FRESH_SIGN_IN_REQUIRED", "Please sign in again to set up your authenticator."},
	{auth.ErrTOTPNotEnrolled, http.StatusConflict, "MFA_NOT_ENROLLED", "Set up your authenticator app first."},
	{auth.ErrTOTPNoEnrolment, http.StatusConflict, "MFA_SETUP_EXPIRED", "That setup has expired. Please start again."},
	{auth.ErrTOTPInvalid, http.StatusBadRequest, "INVALID_CODE", "That code is incorrect or has already been used."},
	{auth.ErrTOTPLocked, http.StatusTooManyRequests, "TOO_MANY_ATTEMPTS", "Too many incorrect codes. Please wait a few minutes."},
	{auth.ErrNotStaff, http.StatusForbidden, "NOT_STAFF", "This number does not have staff access."},
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
	{verification.ErrUnavailable, http.StatusServiceUnavailable, "UPLOADS_UNAVAILABLE", "Document uploads are not available right now."},
	{verification.ErrProfileMissing, http.StatusNotFound, "DRIVER_PROFILE_MISSING", "Finish setting up your driver profile first."},
	{verification.ErrInvalidPlate, http.StatusBadRequest, "INVALID_PLATE", "Enter a valid Kenyan number plate."},
	{verification.ErrApplicationBlocked, http.StatusForbidden, "VERIFICATION_BLOCKED", "Your account is suspended. Please contact support."},
	{verification.ErrNoOpenApplication, http.StatusConflict, "NO_OPEN_APPLICATION", "Start your application first."},
	{verification.ErrApplicationClosed, http.StatusConflict, "APPLICATION_CLOSED", "This application has already been decided."},
	{verification.ErrNotFound, http.StatusNotFound, "NOT_FOUND", "That could not be found."},
	{verification.ErrInvalidDocument, http.StatusBadRequest, "INVALID_DOCUMENT_TYPE", "That document is not needed."},
	{verification.ErrInvalidFile, http.StatusBadRequest, "INVALID_FILE", "Use a JPEG, PNG or PDF under 10 MB."},
	{verification.ErrExpiryRequired, http.StatusBadRequest, "EXPIRY_REQUIRED", "Enter this document's expiry date. It must be in the future."},
	{verification.ErrUploadExpired, http.StatusConflict, "UPLOAD_EXPIRED", "That upload has expired. Please upload the file again."},
	{verification.ErrUploadMissing, http.StatusConflict, "UPLOAD_NOT_FOUND", "We did not receive that file. Please upload it again."},
	{verification.ErrRateLimited, http.StatusTooManyRequests, "RATE_LIMITED", "Too many uploads. Please wait and try again."},
	{verification.ErrInvalidDecision, http.StatusBadRequest, "INVALID_DECISION", "That decision is not available here."},
	{verification.ErrReasonRequired, http.StatusBadRequest, "REASON_REQUIRED", "Give a reason of up to 500 characters."},
	{verification.ErrSelfReview, http.StatusForbidden, "SELF_REVIEW", "You cannot review your own documents."},
	{verification.ErrDocumentNotReady, http.StatusConflict, "DOCUMENT_NOT_READY", "This document cannot be reviewed yet."},
	{verification.ErrDocumentsMissing, http.StatusConflict, "DOCUMENTS_INCOMPLETE", "Every required document must be validated first."},
	{notifications.ErrNotFound, http.StatusNotFound, "NOT_FOUND", "That notification could not be found."},
	{notifications.ErrInvalidToken, http.StatusBadRequest, "INVALID_PUSH_TOKEN", "That device token is not valid."},
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
