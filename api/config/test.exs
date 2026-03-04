import Config

postgres_db = System.fetch_env!("POSTGRES_DB")
postgres_user = System.fetch_env!("POSTGRES_USER")
postgres_password = System.fetch_env!("POSTGRES_PASSWORD")
postgres_host = System.get_env("POSTGRES_HOST") || "localhost"
test_partition = System.get_env("MIX_TEST_PARTITION")
test_db_name = "#{postgres_db}_test#{test_partition}"

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :liddr, Liddr.Repo,
  username: postgres_user,
  password: postgres_password,
  hostname: postgres_host,
  database: test_db_name,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :liddr, LiddrWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "Yco2BZMN836sEW7wLPvDfjPjlc5crbHL1G/CX9+Pa2AmkfP5Ns6BHsep2rFowZ8d",
  server: false

# In test we don't send emails
config :liddr, Liddr.Mailer, adapter: Swoosh.Adapters.Test

# Keep Oban deterministic in tests.
config :liddr, Oban, testing: :manual

# Test-only helper to assert OTP challenge flow without SMS/email integration.
config :liddr, :auth_debug_otp, true
config :liddr, :rides_dispatch_async, false
config :liddr, :malware_scan_enabled, false
config :liddr, :ocr_enabled, false
config :liddr, :ocr_pdf_enabled, false

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
