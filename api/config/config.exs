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
config :liddr, :auth_debug_otp, false
config :liddr, :auth_debug_otp_targets, []

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
       {"30 1 * * *", Liddr.Verification.ExpiryMonitorWorker}
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
