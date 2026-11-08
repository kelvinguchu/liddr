# API Contract

Generated from `api/lib/liddr_web/router.ex` via `mix liddr.contract.sync`.
Do not hand-edit this file.

## Response Envelope

- Success: `{ "data": ... }`
- Error: `{ "error": { "code": "...", "message": "...", "details": ...? } }`

## Idempotency

- Header: `idempotency-key` (8-120 chars).
- Reusing the same key with different payload returns `409 IDEMPOTENCY_KEY_REUSED`.
- Same key while request is still processing returns `409 IDEMPOTENCY_REQUEST_IN_PROGRESS`.
- Invalid key format returns `422 INVALID_IDEMPOTENCY_KEY`.

## Real-time Channels

- `driver:*` via `LiddrWeb.DriverChannel` (requires socket token auth).
- `ride:*` via `LiddrWeb.RideChannel` (requires socket token auth).

## HTTP Routes

| Method | Path | Access | Idempotent | Controller#Action |
|---|---|---|---|---|
| GET | `/api/health` | `public` | `no` | `LiddrWeb.HealthController#show` |
| GET | `/api/auth/methods` | `public` | `no` | `LiddrWeb.AuthController#methods` |
| POST | `/api/auth/register/rider` | `public` | `no` | `LiddrWeb.AuthController#register_rider` |
| POST | `/api/auth/register/driver` | `public` | `no` | `LiddrWeb.AuthController#register_driver` |
| POST | `/api/auth/challenges` | `public` | `no` | `LiddrWeb.AuthController#challenge` |
| POST | `/api/auth/challenges/verify` | `public` | `no` | `LiddrWeb.AuthController#verify_challenge` |
| POST | `/api/auth/refresh` | `public` | `no` | `LiddrWeb.AuthController#refresh` |
| POST | `/api/auth/logout` | `public` | `no` | `LiddrWeb.AuthController#logout` |
| GET | `/api/reports/categories` | `public` | `no` | `LiddrWeb.ReportController#categories` |
| GET | `/api/openapi` | `public` | `no` | `OpenApiSpex.Plug.RenderSpec#[]` |
| GET | `/api/docs` | `public` | `no` | `OpenApiSpex.Plug.SwaggerUI#[path: "/api/openapi"]` |
| POST | `/api/payments/mpesa/stk-callback` | `public_webhook` | `no` | `LiddrWeb.MpesaWebhookController#stk_callback` |
| POST | `/api/payments/c2b-validation` | `public_webhook` | `no` | `LiddrWeb.MpesaWebhookController#c2b_validation` |
| POST | `/api/payments/c2b-confirmation` | `public_webhook` | `no` | `LiddrWeb.MpesaWebhookController#c2b_confirmation` |
| POST | `/api/payments/tx-status-callback` | `public_webhook` | `no` | `LiddrWeb.MpesaWebhookController#tx_status_callback` |
| POST | `/api/payments/mpesa/c2b-validation` | `public_webhook` | `no` | `LiddrWeb.MpesaWebhookController#c2b_validation` |
| POST | `/api/payments/mpesa/c2b-confirmation` | `public_webhook` | `no` | `LiddrWeb.MpesaWebhookController#c2b_confirmation` |
| POST | `/api/payments/mpesa/tx-status-callback` | `public_webhook` | `no` | `LiddrWeb.MpesaWebhookController#tx_status_callback` |
| POST | `/api/disputes` | `authenticated` | `yes` | `LiddrWeb.DisputeController#create` |
| GET | `/api/disputes/me` | `authenticated` | `no` | `LiddrWeb.DisputeController#index` |
| GET | `/api/disputes/me/compensations` | `authenticated` | `no` | `LiddrWeb.DisputeController#compensations` |
| POST | `/api/reports` | `authenticated` | `yes` | `LiddrWeb.ReportController#create` |
| GET | `/api/notifications/summary` | `authenticated` | `no` | `LiddrWeb.RideNotificationController#summary` |
| GET | `/api/notifications` | `authenticated` | `no` | `LiddrWeb.RideNotificationController#index` |
| POST | `/api/notifications/:id/ack` | `authenticated` | `no` | `LiddrWeb.RideNotificationController#ack` |
| POST | `/api/push-tokens` | `authenticated` | `no` | `LiddrWeb.PushTokenController#upsert` |
| DELETE | `/api/push-tokens` | `authenticated` | `no` | `LiddrWeb.PushTokenController#revoke` |
| POST | `/api/send/rides/:ride_id/recipient-confirm` | `authenticated` | `no` | `LiddrWeb.SendDeliveryController#confirm_recipient_in_app` |
| GET | `/api/rides/messages/quick-actions` | `authenticated` | `no` | `LiddrWeb.RideMessageController#quick_actions` |
| GET | `/api/rides/:ride_id/shared` | `authenticated` | `no` | `LiddrWeb.SharedRideController#show` |
| GET | `/api/rides/:ride_id/messages` | `authenticated` | `no` | `LiddrWeb.RideMessageController#index` |
| POST | `/api/rides/:ride_id/messages` | `authenticated` | `no` | `LiddrWeb.RideMessageController#create` |
| POST | `/api/rides/:ride_id/messages/:id/read` | `authenticated` | `no` | `LiddrWeb.RideMessageController#mark_read` |
| POST | `/api/rides/:ride_id/messages/:id/hide` | `authenticated` | `no` | `LiddrWeb.RideMessageController#hide` |
| POST | `/api/rides/:ride_id/messages/:id/report` | `authenticated` | `no` | `LiddrWeb.RideMessageController#report` |
| GET | `/api/ratings/me/pending` | `authenticated` | `no` | `LiddrWeb.RatingController#pending` |
| POST | `/api/rides/:ride_id/rate` | `authenticated` | `yes` | `LiddrWeb.RatingController#rate` |
| POST | `/api/rides/:ride_id/rate/skip` | `authenticated` | `yes` | `LiddrWeb.RatingController#skip` |
| POST | `/api/rides/quote` | `authenticated` | `no` | `LiddrWeb.RideController#quote` |
| POST | `/api/rides/requests` | `authenticated` | `yes` | `LiddrWeb.RideController#request` |
| POST | `/api/send/quote` | `authenticated` | `no` | `LiddrWeb.SendController#quote` |
| POST | `/api/send/requests` | `authenticated` | `yes` | `LiddrWeb.SendController#request` |
| GET | `/api/send/history/sender` | `authenticated` | `no` | `LiddrWeb.SendController#sender_history` |
| GET | `/api/rides/:ride_id/pickup-health` | `authenticated` | `no` | `LiddrWeb.RideController#pickup_health` |
| POST | `/api/rides/:ride_id/reassign` | `authenticated` | `yes` | `LiddrWeb.RideController#reassign` |
| POST | `/api/rides/:ride_id/cancel` | `authenticated` | `yes` | `LiddrWeb.RideController#rider_cancel` |
| POST | `/api/rides/:ride_id/shared/members/:member_id/cancel` | `authenticated` | `no` | `LiddrWeb.SharedRideController#cancel_member` |
| POST | `/api/rides/:ride_id/destination-change-requests` | `authenticated` | `yes` | `LiddrWeb.RideDestinationChangeController#request` |
| GET | `/api/rides/history/rider` | `authenticated` | `no` | `LiddrWeb.RideController#rider_history` |
| POST | `/api/drivers/me/online` | `authenticated` | `no` | `LiddrWeb.DriverAvailabilityController#online` |
| POST | `/api/drivers/me/offline` | `authenticated` | `no` | `LiddrWeb.DriverAvailabilityController#offline` |
| POST | `/api/drivers/me/location` | `authenticated` | `no` | `LiddrWeb.DriverLocationController#upsert` |
| POST | `/api/verification/applications` | `authenticated` | `no` | `LiddrWeb.VerificationController#start_application` |
| POST | `/api/verification/uploads/presign` | `authenticated` | `no` | `LiddrWeb.VerificationController#presign_upload` |
| POST | `/api/verification/documents` | `authenticated` | `no` | `LiddrWeb.VerificationController#submit_document` |
| GET | `/api/verification/status` | `authenticated` | `no` | `LiddrWeb.VerificationController#status` |
| GET | `/api/subscriptions/me` | `authenticated` | `no` | `LiddrWeb.SubscriptionController#current` |
| POST | `/api/subscriptions/pay` | `authenticated` | `yes` | `LiddrWeb.SubscriptionController#pay` |
| GET | `/api/subscriptions/me/history` | `authenticated` | `no` | `LiddrWeb.SubscriptionController#history` |
| GET | `/api/rides/offers` | `authenticated` | `no` | `LiddrWeb.RideController#driver_offers` |
| POST | `/api/rides/offers/:offer_id/accept` | `authenticated` | `yes` | `LiddrWeb.RideController#accept_offer` |
| POST | `/api/rides/offers/:offer_id/reject` | `authenticated` | `no` | `LiddrWeb.RideController#reject_offer` |
| POST | `/api/rides/:ride_id/driver-arriving` | `authenticated` | `no` | `LiddrWeb.RideController#driver_arriving` |
| POST | `/api/rides/:ride_id/arrived` | `authenticated` | `no` | `LiddrWeb.RideController#driver_arrived` |
| POST | `/api/rides/:ride_id/start` | `authenticated` | `yes` | `LiddrWeb.RideController#start_trip` |
| POST | `/api/rides/:ride_id/complete` | `authenticated` | `yes` | `LiddrWeb.RideController#complete` |
| POST | `/api/rides/:ride_id/driver-cancel` | `authenticated` | `yes` | `LiddrWeb.RideController#driver_cancel` |
| POST | `/api/rides/:ride_id/no-show` | `authenticated` | `no` | `LiddrWeb.RideController#rider_no_show` |
| POST | `/api/rides/:ride_id/shared/members/:member_id/no-show` | `authenticated` | `no` | `LiddrWeb.SharedRideController#mark_member_no_show` |
| POST | `/api/rides/:ride_id/shared/members/:member_id/arrive-pickup` | `authenticated` | `no` | `LiddrWeb.SharedRideController#arrive_member_pickup` |
| POST | `/api/rides/:ride_id/shared/members/:member_id/picked-up` | `authenticated` | `no` | `LiddrWeb.SharedRideController#mark_member_picked_up` |
| POST | `/api/rides/:ride_id/shared/members/:member_id/dropped-off` | `authenticated` | `no` | `LiddrWeb.SharedRideController#mark_member_dropped_off` |
| POST | `/api/rides/:ride_id/destination-change-requests/:id/accept` | `authenticated` | `yes` | `LiddrWeb.RideDestinationChangeController#accept` |
| POST | `/api/rides/:ride_id/destination-change-requests/:id/reject` | `authenticated` | `yes` | `LiddrWeb.RideDestinationChangeController#reject` |
| POST | `/api/send/rides/:ride_id/proof-uploads/presign` | `authenticated` | `no` | `LiddrWeb.SendDeliveryController#presign_proof` |
| POST | `/api/send/rides/:ride_id/pickup-proof` | `authenticated` | `no` | `LiddrWeb.SendDeliveryController#pickup_proof` |
| POST | `/api/send/rides/:ride_id/dropoff-proof` | `authenticated` | `no` | `LiddrWeb.SendDeliveryController#dropoff_proof` |
| GET | `/api/send/history/courier` | `authenticated` | `no` | `LiddrWeb.SendController#courier_history` |
| GET | `/api/rides/history/driver` | `authenticated` | `no` | `LiddrWeb.RideController#driver_history` |
| POST | `/api/auth/step-up/challenges` | `public` | `no` | `LiddrWeb.AuthController#request_step_up_challenge` |
| POST | `/api/auth/step-up/verify` | `public` | `no` | `LiddrWeb.AuthController#verify_step_up_challenge` |
| POST | `/api/auth/mfa/totp/setup` | `public` | `no` | `LiddrWeb.AuthController#request_totp_setup` |
| POST | `/api/auth/mfa/totp/confirm` | `public` | `no` | `LiddrWeb.AuthController#confirm_totp_setup` |
| GET | `/api/ops/disputes` | `ops_admin` | `no` | `LiddrWeb.DisputeOpsController#index` |
| GET | `/api/ops/disputes/compensations` | `ops_admin` | `no` | `LiddrWeb.DisputeOpsController#compensations` |
| GET | `/api/ops/subscriptions/drivers/:driver_user_id` | `ops_admin` | `no` | `LiddrWeb.SubscriptionOpsController#driver_lookup` |
| GET | `/api/ops/subscriptions/payments/checkout/:checkout_request_id` | `ops_admin` | `no` | `LiddrWeb.SubscriptionOpsController#payment_lookup` |
| GET | `/api/ops/rides/integrity/users/:user_id` | `ops_admin` | `no` | `LiddrWeb.RideOpsController#integrity_lookup` |
| GET | `/api/ops/rides/pickup-watchdog/summary` | `ops_admin` | `no` | `LiddrWeb.RideOpsController#pickup_watchdog_summary` |
| GET | `/api/ops/rides/offer-lock/health` | `ops_admin` | `no` | `LiddrWeb.RideOpsController#offer_lock_health` |
| GET | `/api/ops/rides/:ride_id/notifications` | `ops_admin` | `no` | `LiddrWeb.RideOpsController#ride_notifications` |
| GET | `/api/moderation/verification/applications` | `ops_admin` | `no` | `LiddrWeb.VerificationOpsController#list_applications` |
| GET | `/api/moderation/verification/documents` | `ops_admin` | `no` | `LiddrWeb.VerificationOpsController#list_documents` |
| GET | `/api/moderation/reports` | `ops_admin` | `no` | `LiddrWeb.ModerationController#list_reports` |
| GET | `/api/moderation/enforcements` | `ops_admin` | `no` | `LiddrWeb.ModerationController#list_enforcements` |
| GET | `/api/moderation/enforcements/metrics` | `ops_admin` | `no` | `LiddrWeb.ModerationController#enforcement_metrics` |
| GET | `/api/ops/ratings` | `ops_admin` | `no` | `LiddrWeb.RatingOpsController#index` |
| GET | `/api/ops/ratings/excluded` | `ops_admin` | `no` | `LiddrWeb.RatingOpsController#excluded` |
| GET | `/api/ops/ratings/users/:rated_user_id/guardrails` | `ops_admin` | `no` | `LiddrWeb.RatingOpsController#guardrails` |
| POST | `/api/ops/disputes/:id/resolve` | `ops_admin` | `yes` | `LiddrWeb.DisputeOpsController#resolve` |
| POST | `/api/ops/disputes/compensations/:id/mark-paid` | `ops_admin` | `yes` | `LiddrWeb.DisputeOpsController#mark_compensation_paid` |
| POST | `/api/ops/disputes/compensations/:id/cancel` | `ops_admin` | `yes` | `LiddrWeb.DisputeOpsController#cancel_compensation` |
| POST | `/api/ops/mpesa/c2b/register-urls` | `ops_admin` | `yes` | `LiddrWeb.SubscriptionOpsController#register_c2b_urls` |
| POST | `/api/ops/mpesa/payments/checkout/:checkout_request_id/query-tx-status` | `ops_admin` | `yes` | `LiddrWeb.SubscriptionOpsController#query_tx_status` |
| POST | `/api/ops/rides/integrity/reconcile-prepay-modes` | `ops_admin` | `yes` | `LiddrWeb.RideOpsController#reconcile_prepay_modes` |
| POST | `/api/moderation/verification/applications/:id/reviews` | `ops_admin` | `yes` | `LiddrWeb.VerificationOpsController#review_application` |
| POST | `/api/moderation/verification/documents/:id/reviews` | `ops_admin` | `yes` | `LiddrWeb.VerificationOpsController#review_document` |
| POST | `/api/moderation/verification/documents/reviews/bulk` | `ops_admin` | `yes` | `LiddrWeb.VerificationOpsController#review_documents_bulk` |
| PATCH | `/api/moderation/reports/:id/triage` | `ops_admin` | `yes` | `LiddrWeb.ModerationController#triage_report` |
| POST | `/api/moderation/reports/:id/reviews` | `ops_admin` | `yes` | `LiddrWeb.ModerationController#review_report` |
| POST | `/api/moderation/enforcements` | `ops_admin` | `yes` | `LiddrWeb.ModerationController#create_enforcement` |
| POST | `/api/moderation/enforcements/reconcile-expired` | `ops_admin` | `yes` | `LiddrWeb.ModerationController#reconcile_enforcements` |
| POST | `/api/ops/ratings/:id/nullify` | `ops_admin` | `yes` | `LiddrWeb.RatingOpsController#nullify` |
| POST | `/api/ops/ratings/:id/reinstate` | `ops_admin` | `yes` | `LiddrWeb.RatingOpsController#reinstate` |
| GET | `/api/rides/integrity/me` | `authenticated` | `no` | `LiddrWeb.RideIntegrityController#me` |
| GET | `/api/rides/:ride_id/current-status` | `authenticated` | `no` | `LiddrWeb.RideController#current_status` |
| GET | `/api/rides/:ride_id/events` | `authenticated` | `no` | `LiddrWeb.RideController#events` |
| GET | `/api/rides/:ride_id/incidents` | `authenticated` | `no` | `LiddrWeb.RideController#incidents` |
| GET | `/api/rides/:ride_id` | `authenticated` | `no` | `LiddrWeb.RideController#show` |
