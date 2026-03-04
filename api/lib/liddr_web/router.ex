defmodule LiddrWeb.Router do
  use LiddrWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :api_auth do
    plug LiddrWeb.Plugs.AuthenticateAccessToken
  end

  pipeline :require_rider_or_driver do
    plug LiddrWeb.Plugs.RequireAnyRole, roles: ["rider", "driver"]
  end

  pipeline :require_rider do
    plug LiddrWeb.Plugs.RequireAnyRole, roles: ["rider"]
  end

  pipeline :require_driver do
    plug LiddrWeb.Plugs.RequireAnyRole, roles: ["driver"]
  end

  pipeline :require_ops_or_admin do
    plug LiddrWeb.Plugs.RequireAnyRole, roles: ["ops", "admin"]
  end

  pipeline :require_ops_ip do
    plug LiddrWeb.Plugs.EnforceIpAllowlist,
      env_key: "OPS_IP_ALLOWLIST",
      scope: "ops_admin"
  end

  pipeline :mpesa_webhook_security do
    plug LiddrWeb.Plugs.EnforceIpAllowlist,
      env_key: "MPESA_CALLBACK_IP_ALLOWLIST",
      scope: "mpesa_callback"
  end

  scope "/api", LiddrWeb do
    pipe_through :api

    get "/health", HealthController, :show
    get "/auth/methods", AuthController, :methods
    post "/auth/register/rider", AuthController, :register_rider
    post "/auth/register/driver", AuthController, :register_driver
    post "/auth/challenges", AuthController, :challenge
    post "/auth/challenges/verify", AuthController, :verify_challenge
    post "/auth/refresh", AuthController, :refresh
    post "/auth/logout", AuthController, :logout
    get "/reports/categories", ReportController, :categories
  end

  scope "/api", LiddrWeb do
    pipe_through [:api, :mpesa_webhook_security]

    post "/payments/mpesa/stk-callback", MpesaWebhookController, :stk_callback
    post "/payments/c2b-validation", MpesaWebhookController, :c2b_validation
    post "/payments/c2b-confirmation", MpesaWebhookController, :c2b_confirmation
    post "/payments/tx-status-callback", MpesaWebhookController, :tx_status_callback
    post "/payments/mpesa/c2b-validation", MpesaWebhookController, :c2b_validation
    post "/payments/mpesa/c2b-confirmation", MpesaWebhookController, :c2b_confirmation
    post "/payments/mpesa/tx-status-callback", MpesaWebhookController, :tx_status_callback
  end

  scope "/api", LiddrWeb do
    pipe_through [:api, :api_auth, :require_rider_or_driver]

    post "/reports", ReportController, :create
    get "/ride-notifications", RideNotificationController, :index
    post "/ride-notifications/:id/ack", RideNotificationController, :ack
    get "/ratings/me/pending", RatingController, :pending
    post "/rides/:ride_id/rate", RatingController, :rate
    post "/rides/:ride_id/rate/skip", RatingController, :skip
  end

  scope "/api", LiddrWeb do
    pipe_through [:api, :api_auth, :require_rider]

    post "/rides/quote", RideController, :quote
    post "/rides/requests", RideController, :request
    get "/rides/:ride_id/pickup-health", RideController, :pickup_health
    post "/rides/:ride_id/reassign", RideController, :reassign
    post "/rides/:ride_id/cancel", RideController, :rider_cancel
    post "/rides/:ride_id/destination-change-requests", RideDestinationChangeController, :request
    get "/rides/history/rider", RideController, :rider_history
  end

  scope "/api", LiddrWeb do
    pipe_through [:api, :api_auth, :require_driver]

    post "/drivers/me/online", DriverAvailabilityController, :online
    post "/drivers/me/offline", DriverAvailabilityController, :offline
    post "/drivers/me/location", DriverLocationController, :upsert
    post "/verification/applications", VerificationController, :start_application
    post "/verification/uploads/presign", VerificationController, :presign_upload
    post "/verification/documents", VerificationController, :submit_document
    get "/verification/status", VerificationController, :status
    get "/subscriptions/me", SubscriptionController, :current
    post "/subscriptions/pay", SubscriptionController, :pay
    get "/subscriptions/me/history", SubscriptionController, :history
    get "/rides/offers", RideController, :driver_offers
    post "/rides/offers/:offer_id/accept", RideController, :accept_offer
    post "/rides/offers/:offer_id/reject", RideController, :reject_offer
    post "/rides/:ride_id/driver-arriving", RideController, :driver_arriving
    post "/rides/:ride_id/arrived", RideController, :driver_arrived
    post "/rides/:ride_id/start", RideController, :start_trip
    post "/rides/:ride_id/complete", RideController, :complete
    post "/rides/:ride_id/driver-cancel", RideController, :driver_cancel
    post "/rides/:ride_id/no-show", RideController, :rider_no_show

    post "/rides/:ride_id/destination-change-requests/:id/accept",
         RideDestinationChangeController,
         :accept

    post "/rides/:ride_id/destination-change-requests/:id/reject",
         RideDestinationChangeController,
         :reject

    get "/rides/history/driver", RideController, :driver_history
  end

  scope "/api", LiddrWeb do
    pipe_through [:api, :require_ops_ip, :api_auth, :require_ops_or_admin]

    get "/ops/subscriptions/drivers/:driver_user_id", SubscriptionOpsController, :driver_lookup

    get "/ops/subscriptions/payments/checkout/:checkout_request_id",
        SubscriptionOpsController,
        :payment_lookup

    post "/ops/mpesa/c2b/register-urls", SubscriptionOpsController, :register_c2b_urls

    post "/ops/mpesa/payments/checkout/:checkout_request_id/query-tx-status",
         SubscriptionOpsController,
         :query_tx_status

    get "/ops/rides/integrity/users/:user_id", RideOpsController, :integrity_lookup
    post "/ops/rides/integrity/reconcile-prepay-modes", RideOpsController, :reconcile_prepay_modes
    get "/ops/rides/pickup-watchdog/summary", RideOpsController, :pickup_watchdog_summary
    get "/ops/rides/:ride_id/notifications", RideOpsController, :ride_notifications

    get "/moderation/verification/applications", VerificationOpsController, :list_applications
    get "/moderation/verification/documents", VerificationOpsController, :list_documents

    post "/moderation/verification/applications/:id/reviews",
         VerificationOpsController,
         :review_application

    post "/moderation/verification/documents/:id/reviews",
         VerificationOpsController,
         :review_document

    post "/moderation/verification/documents/reviews/bulk",
         VerificationOpsController,
         :review_documents_bulk

    get "/moderation/reports", ModerationController, :list_reports
    patch "/moderation/reports/:id/triage", ModerationController, :triage_report
    post "/moderation/reports/:id/reviews", ModerationController, :review_report
    get "/moderation/enforcements", ModerationController, :list_enforcements
    get "/moderation/enforcements/metrics", ModerationController, :enforcement_metrics
    post "/moderation/enforcements", ModerationController, :create_enforcement

    post "/moderation/enforcements/reconcile-expired",
         ModerationController,
         :reconcile_enforcements

    get "/ops/ratings", RatingOpsController, :index
    get "/ops/ratings/excluded", RatingOpsController, :excluded
    get "/ops/ratings/users/:rated_user_id/guardrails", RatingOpsController, :guardrails
    post "/ops/ratings/:id/nullify", RatingOpsController, :nullify
    post "/ops/ratings/:id/reinstate", RatingOpsController, :reinstate
  end

  scope "/api", LiddrWeb do
    pipe_through [:api, :api_auth, :require_rider_or_driver]

    get "/rides/integrity/me", RideIntegrityController, :me
    get "/rides/:ride_id/events", RideController, :events
    get "/rides/:ride_id/incidents", RideController, :incidents
    get "/rides/:ride_id", RideController, :show
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:liddr, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:fetch_session, :protect_from_forgery]

      live_dashboard "/dashboard", metrics: LiddrWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
