package httpapi

import (
	"errors"
	"net/http"

	"github.com/kelvinguchu/liddr/apps/api/internal/auth"
	"github.com/kelvinguchu/liddr/apps/api/internal/dispatch"
	"github.com/kelvinguchu/liddr/apps/api/internal/disputes"
	"github.com/kelvinguchu/liddr/apps/api/internal/messages"
	"github.com/kelvinguchu/liddr/apps/api/internal/moderation"
	"github.com/kelvinguchu/liddr/apps/api/internal/notifications"
	"github.com/kelvinguchu/liddr/apps/api/internal/payments"
	"github.com/kelvinguchu/liddr/apps/api/internal/ratings"
	"github.com/kelvinguchu/liddr/apps/api/internal/rides"
	"github.com/kelvinguchu/liddr/apps/api/internal/send"
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
	{moderation.ErrNotFound, http.StatusNotFound, "NOT_FOUND", "That could not be found."},
	{moderation.ErrInvalidCategory, http.StatusBadRequest, "INVALID_CATEGORY", "Choose a valid reason."},
	{moderation.ErrInvalidDescription, http.StatusBadRequest, "INVALID_DESCRIPTION", "Describe what happened in up to 2,000 characters."},
	{moderation.ErrNotParticipant, http.StatusNotFound, "NOT_FOUND", "That ride could not be found."},
	{moderation.ErrNoOtherParty, http.StatusConflict, "NO_OTHER_PARTY", "No driver was assigned to this ride."},
	{moderation.ErrWrongParty, http.StatusBadRequest, "WRONG_PARTY", "That reason does not apply here."},
	{moderation.ErrRateLimited, http.StatusTooManyRequests, "RATE_LIMITED", "Too many reports today. Please contact support."},
	{moderation.ErrInvalidDecision, http.StatusBadRequest, "INVALID_DECISION", "That decision is not available."},
	{moderation.ErrInvalidStatus, http.StatusBadRequest, "INVALID_STATUS", "That status is not available."},
	{moderation.ErrReportClosed, http.StatusConflict, "REPORT_CLOSED", "This report has already been closed."},
	{moderation.ErrConflictOfInterest, http.StatusForbidden, "CONFLICT_OF_INTEREST", "You cannot act on a case involving yourself."},
	{moderation.ErrInvalidEnd, http.StatusBadRequest, "INVALID_END_TIME", "Choose an end time within the next year."},
	{moderation.ErrEnforcementClosed, http.StatusConflict, "ENFORCEMENT_CLOSED", "This penalty is no longer active."},
	{ratings.ErrNotRateable, http.StatusConflict, "RATING_NOT_AVAILABLE", "This ride can no longer be rated."},
	{ratings.ErrInvalidScore, http.StatusBadRequest, "INVALID_SCORE", "Choose between one and five stars."},
	{ratings.ErrReasonsRequired, http.StatusBadRequest, "REASON_REQUIRED", "Tell us what went wrong."},
	{ratings.ErrInvalidTags, http.StatusBadRequest, "INVALID_TAGS", "Those reasons are not valid."},
	{ratings.ErrInvalidComment, http.StatusBadRequest, "INVALID_COMMENT", "Keep your comment under 200 characters."},
	{ratings.ErrNotFound, http.StatusNotFound, "NOT_FOUND", "That rating could not be found."},
	{ratings.ErrAlreadyDone, http.StatusConflict, "ALREADY_DONE", "That has already been done."},
	{ratings.ErrReasonRequired, http.StatusBadRequest, "REASON_REQUIRED", "Give a reason of up to 200 characters."},
	{ratings.ErrSelfAction, http.StatusForbidden, "CONFLICT_OF_INTEREST", "You cannot change your own ratings."},
	{disputes.ErrInvalidType, http.StatusBadRequest, "INVALID_DISPUTE_TYPE", "Choose a valid dispute type."},
	{disputes.ErrRideNotEligible, http.StatusConflict, "RIDE_NOT_ELIGIBLE", "This ride cannot be disputed right now."},
	{disputes.ErrWindowClosed, http.StatusConflict, "DISPUTE_WINDOW_CLOSED", "Disputes must be raised within 48 hours of the ride."},
	{disputes.ErrRideLimit, http.StatusTooManyRequests, "DISPUTE_RIDE_LIMIT", "You have raised the maximum disputes for this ride."},
	{disputes.ErrWeeklyLimit, http.StatusTooManyRequests, "DISPUTE_WEEKLY_LIMIT", "You have raised too many disputes this week. Please contact support."},
	{disputes.ErrNotFound, http.StatusNotFound, "NOT_FOUND", "That dispute could not be found."},
	{disputes.ErrInvalidOutcome, http.StatusBadRequest, "INVALID_OUTCOME", "That outcome is not available."},
	{disputes.ErrInvalidAmount, http.StatusBadRequest, "INVALID_AMOUNT", "The amount must be positive and no more than the fare."},
	{disputes.ErrNotRefundable, http.StatusConflict, "NOT_REFUNDABLE", "Only the rider who paid this fare can be compensated."},
	{disputes.ErrAlreadySettled, http.StatusConflict, "ALREADY_SETTLED", "This compensation has already been settled."},
	{disputes.ErrInvalidChannel, http.StatusBadRequest, "INVALID_CHANNEL", "Choose a valid payment channel."},
	{disputes.ErrReferenceNeeded, http.StatusBadRequest, "REFERENCE_REQUIRED", "Enter the payment reference."},
	{disputes.ErrSelfAction, http.StatusForbidden, "CONFLICT_OF_INTEREST", "You cannot settle your own case."},
	{rides.ErrWrongBookingType, http.StatusBadRequest, "WRONG_BOOKING_TYPE", "That price cannot be booked this way."},
	{rides.ErrPickupProofRequired, http.StatusConflict, "PICKUP_PROOF_REQUIRED", "Photograph the package before you start."},
	{rides.ErrDropoffProofRequired, http.StatusConflict, "DROPOFF_PROOF_REQUIRED", "Photograph the delivered package first."},
	{rides.ErrRecipientPending, http.StatusConflict, "RECIPIENT_PENDING", "Waiting for the recipient. You can finish after ten minutes."},
	{rides.ErrPackageCollected, http.StatusConflict, "PACKAGE_COLLECTED", "The package has already been collected."},
	{rides.ErrBookingRestricted, http.StatusForbidden, "BOOKING_RESTRICTED", "Bookings are paused after repeated cancellations."},
	{rides.ErrReassignNotAllowed, http.StatusConflict, "REASSIGN_NOT_AVAILABLE", "Your driver is on the way. You can cancel if your plans changed."},
	{rides.ErrDestinationWindow, http.StatusConflict, "DESTINATION_WINDOW_CLOSED", "This trip started too long ago to change destination."},
	{rides.ErrSameDestination, http.StatusBadRequest, "SAME_DESTINATION", "That is already your destination."},
	{rides.ErrDestinationLimit, http.StatusConflict, "DESTINATION_LIMIT", "The destination cannot be changed again on this trip."},
	{rides.ErrDestinationPending, http.StatusConflict, "DESTINATION_PENDING", "Please wait for the driver's answer to your last request."},
	{rides.ErrDestinationNotFound, http.StatusNotFound, "NOT_FOUND", "That request could not be found."},
	{rides.ErrDestinationStale, http.StatusConflict, "DESTINATION_STALE", "That request has lapsed."},
	{messages.ErrNotFound, http.StatusNotFound, "NOT_FOUND", "That could not be found."},
	{messages.ErrNoDriver, http.StatusConflict, "NO_DRIVER_YET", "Chat opens once a driver accepts."},
	{messages.ErrClosed, http.StatusConflict, "CHAT_CLOSED", "This ride has ended, so chat is closed."},
	{messages.ErrInvalidBody, http.StatusBadRequest, "INVALID_MESSAGE", "Messages can be up to 1,000 characters."},
	{messages.ErrInvalidAction, http.StatusBadRequest, "INVALID_QUICK_ACTION", "That quick message is not available."},
	{messages.ErrRestricted, http.StatusForbidden, "MESSAGES_RESTRICTED", "You cannot send messages right now."},
	{messages.ErrRateLimited, http.StatusTooManyRequests, "RATE_LIMITED", "You are sending messages too quickly."},
	{messages.ErrNotRecipient, http.StatusForbidden, "FORBIDDEN", "That message was not sent to you."},
	{messages.ErrOwnMessage, http.StatusBadRequest, "OWN_MESSAGE", "You cannot report your own message."},
	{send.ErrUnavailable, http.StatusServiceUnavailable, "UPLOADS_UNAVAILABLE", "Photo uploads are not available right now."},
	{send.ErrInvalidDetails, http.StatusBadRequest, "INVALID_DELIVERY", "Check the delivery details and try again."},
	{send.ErrInvalidPhone, http.StatusBadRequest, "INVALID_PHONE", "Enter a Kenyan mobile number, such as 0712345678."},
	{send.ErrInvalidPayment, http.StatusBadRequest, "INVALID_PAYMENT_OPTION", "A recipient can only pay on delivery."},
	{send.ErrAckRequired, http.StatusConflict, "LIABILITY_ACK_REQUIRED", "Please confirm you accept responsibility for this item."},
	{send.ErrNotFound, http.StatusNotFound, "NOT_FOUND", "That delivery could not be found."},
	{send.ErrInvalidProof, http.StatusBadRequest, "INVALID_PROOF", "Use a JPEG or PNG photo under 10 MB."},
	{send.ErrWrongState, http.StatusConflict, "INVALID_DELIVERY_STATE", "That is not possible at this stage of the delivery."},
	{send.ErrUploadExpired, http.StatusConflict, "UPLOAD_EXPIRED", "That upload has expired. Please upload the photo again."},
	{send.ErrUploadMissing, http.StatusConflict, "UPLOAD_NOT_FOUND", "We did not receive that photo. Please upload it again."},
	{send.ErrNotRecipient, http.StatusForbidden, "FORBIDDEN", "This delivery is not addressed to you."},
	{send.ErrPickupProofFirst, http.StatusConflict, "PICKUP_PROOF_REQUIRED", "Photograph the package at collection first."},
	{send.ErrAlreadyConfirmed, http.StatusConflict, "ALREADY_CONFIRMED", "The recipient has already confirmed."},
	{send.ErrRateLimited, http.StatusTooManyRequests, "RATE_LIMITED", "Too many uploads. Please wait and try again."},
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
