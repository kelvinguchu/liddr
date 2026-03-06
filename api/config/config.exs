# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :liddr,
  ecto_repos: [Liddr.Repo],
  generators: [timestamp_type: :utc_datetime]

config :liddr, :mpesa_client, Liddr.Payments.Mpesa.Client
config :liddr, :google_routes_client, Liddr.Maps.RoutesClient
config :liddr, :ride_market_multiplier, Liddr.Rides.MarketMultiplier
config :liddr, :auth_debug_otp, false
config :liddr, :auth_debug_otp_targets, []
config :liddr, :api_docs_enabled, false
config :liddr, :otp_sms_client, Liddr.Auth.OtpDelivery.HostPinnacle
config :liddr, :ride_supply_index, Liddr.Location.SupplyIndex
config :liddr, :ride_push_client, Liddr.Rides.PushClient.FCM

config :liddr, Liddr.Observability.ModerationMonitor,
  enabled: true,
  window_ms: 60_000,
  report_triage_rate_limited_alert_count: 5,
  report_review_rate_limited_alert_count: 5,
  min_throughput_per_window: 1,
  pending_reports_alert_threshold: 25

config :liddr, Liddr.Security.DataRetention,
  auth_challenges_ttl_days: 7,
  idempotency_ttl_days: 30,
  webhook_events_ttl_days: 180

config :liddr, Liddr.Auth.ChallengeRateLimiter,
  cooldown_seconds: 30,
  identity_window_seconds: 900,
  identity_max_requests: 5,
  ip_window_seconds: 900,
  ip_max_requests: 60,
  device_window_seconds: 900,
  device_max_requests: 40

config :liddr, Liddr.Location.S2, level: 13

config :liddr, Liddr.Location.SupplyIndex,
  zone_ttl_seconds: 180,
  driver_ttl_seconds: 180,
  lookup_cell_limit: 225

config :liddr, Liddr.Rides.Execution.GeoPolicy,
  pickup_arrival_radius_m: 120,
  dropoff_completion_radius_m: 180,
  location_freshness_seconds: 120,
  no_show_wait_seconds: 300,
  require_geofence_on_arrive: true,
  require_geofence_on_complete: true

config :liddr, Liddr.Rides.Integrity.Policy,
  rolling_window_days: 7,
  rider_chargeable_threshold: 5,
  rider_chargeable_escalation_threshold: 8,
  rider_prepay_only_days: 7,
  rider_prepay_only_escalation_days: 14,
  driver_chargeable_threshold: 5,
  driver_chargeable_escalation_threshold: 8,
  driver_temp_suspension_days: 1,
  driver_temp_suspension_escalation_days: 3,
  rider_free_cancel_grace_seconds: 120,
  rider_driver_late_waiver_seconds: 300,
  rider_driver_location_stale_seconds: 120,
  rider_no_progress_elapsed_seconds: 180,
  rider_no_progress_delta_m: 100,
  rider_moving_away_elapsed_seconds: 120,
  rider_moving_away_delta_m: 300,
  rider_pickup_far_distance_m: 2_000,
  rider_prepay_payment_mode: "in_app_mpesa",
  pickup_auto_reassign_enabled: true,
  pickup_auto_reassign_after_seconds: 420,
  pickup_fast_reassign_enabled: true,
  pickup_fast_reassign_after_seconds: 180,
  pickup_auto_cancel_enabled: true,
  pickup_auto_cancel_after_seconds: 900,
  pickup_auto_cancel_min_reassign_count: 1,
  pickup_watchdog_limit: 100

config :liddr, Liddr.Rides.SharedRides.DetourGuard,
  max_extra_detour_m: 2_000.0,
  max_extra_detour_ratio: 0.6

config :liddr, Liddr.Rides.SharedRides.StopEta,
  google_enabled: false,
  fallback_speed_kph: 28.0,
  min_leg_seconds: 60,
  max_leg_seconds: 7_200

config :liddr, Liddr.Rides.DispatchEta,
  enabled: true,
  probe_limit: 8,
  max_concurrency: 4,
  timeout_ms: 1_200,
  fallback_speed_kph: 28.0,
  min_eta_seconds: 30,
  max_eta_seconds: 7_200

config :liddr, Liddr.Rides.DriverLiveness,
  online_max_age_seconds: 90,
  offline_after_seconds: 240

config :liddr, Liddr.Rides.SharedRides.LocationEtaRefresh, min_interval_seconds: 15
config :liddr, Liddr.Rides.PushClient.FCM, timeout_ms: 10_000

config :liddr, Liddr.Rides.OfferLockMonitor,
  enabled: true,
  window_ms: 60_000,
  min_attempts: 20,
  unavailable_ratio_alert_threshold: 0.05

config :liddr, Liddr.Rides.OfferLockExternalAlerting,
  enabled: false,
  provider: "raw",
  webhook_url: nil,
  min_level: "critical",
  timeout_ms: 3_000,
  auth_header: nil,
  pagerduty_routing_key: nil,
  slack_channel: nil,
  slack_username: nil

config :liddr, Liddr.Rides.NotificationRetry,
  limit: 100,
  max_attempts: 3,
  retry_interval_seconds: 30

config :liddr, Liddr.Rides.MessageModerationPolicy,
  report_window_days: 7,
  auto_restrict_threshold: 3,
  signal_cooldown_days: 2

config :liddr, Liddr.Ratings.Policy,
  rating_window_hours: 24,
  rating_decay_per_day: 0.01,
  smoothing_prior_mean: 4.8,
  smoothing_prior_weight: 20,
  enforcement_recent_window_days: 30,
  enforcement_min_recent_ratings: 20,
  non_attributable_reason_tags: [
    "traffic",
    "app_issue",
    "gps_issue",
    "wrong_pickup_pin",
    "co_rider_behavior"
  ]

config :liddr, Liddr.Subscriptions.ReconciliationPolicy,
  limit: 50,
  grace_seconds: 90,
  max_age_seconds: 1_800,
  max_attempts: 8,
  interval_seconds: 60,
  backoff_seconds: [30, 60, 120, 180, 300]

# Configure the endpoint
config :liddr, LiddrWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: LiddrWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Liddr.PubSub,
  live_view: [signing_salt: "+i+CZvtT"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :liddr, Liddr.Mailer, adapter: Swoosh.Adapters.Local

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Configure Oban
config :liddr, Oban,
  repo: Liddr.Repo,
  plugins: [
    {Oban.Plugins.Pruner, max_age: 7 * 24 * 60 * 60},
    {Oban.Plugins.Cron,
     crontab: [
       {"*/5 * * * *", Liddr.Subscriptions.ReconciliationWorker},
       {"*/15 * * * *", Liddr.Subscriptions.MonitorWorker},
       {"*/5 * * * *", Liddr.Moderation.EnforcementLifecycleWorker},
       {"*/10 * * * *", Liddr.Rides.Integrity.ModeLifecycleWorker},
       {"* * * * *", Liddr.Rides.PickupWatchdogWorker},
       {"* * * * *", Liddr.Rides.NotificationRetryWorker},
       {"30 1 * * *", Liddr.Verification.ExpiryMonitorWorker},
       {"15 2 * * *", Liddr.Security.DataRetentionWorker}
     ]}
  ],
  queues: [
    default: 10,
    events: 10,
    payments: 10,
    subscriptions: 10,
    verification: 10
  ]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
