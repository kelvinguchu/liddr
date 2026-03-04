import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/liddr start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :liddr, LiddrWeb.Endpoint, server: true
end

config :liddr, LiddrWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

parse_int_env = fn value, default, min, max ->
  parsed =
    case value do
      nil ->
        default

      int when is_integer(int) ->
        int

      binary when is_binary(binary) ->
        case Integer.parse(String.trim(binary)) do
          {int, ""} -> int
          _ -> default
        end

      _ ->
        default
    end

  if parsed < min or parsed > max, do: default, else: parsed
end

parse_backoff_env = fn value, default ->
  parsed =
    value
    |> case do
      nil -> default
      binary when is_binary(binary) -> String.split(binary, ",", trim: true)
      list when is_list(list) -> list
      _ -> default
    end
    |> Enum.map(fn item -> parse_int_env.(item, nil, 1, 86_400) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()

  if parsed == [], do: default, else: parsed
end

parse_bool_env = fn value, default ->
  case value do
    value when value in [true, "true", "1", "yes", "on"] -> true
    value when value in [false, "false", "0", "no", "off"] -> false
    _ -> default
  end
end

parse_float_env = fn value, default, min, max ->
  parsed =
    case value do
      nil ->
        default

      float when is_float(float) ->
        float

      int when is_integer(int) ->
        int * 1.0

      binary when is_binary(binary) ->
        case Float.parse(String.trim(binary)) do
          {float, ""} -> float
          _ -> default
        end

      _ ->
        default
    end

  if parsed < min or parsed > max, do: default, else: parsed
end

push_client =
  case String.downcase(System.get_env("RIDE_PUSH_CLIENT") || "fcm") do
    "noop" -> Liddr.Rides.PushClient.Noop
    _ -> Liddr.Rides.PushClient.FCM
  end

config :liddr, :ride_push_client, push_client

config :liddr, Liddr.Location.Redis, url: System.get_env("REDIS_URL")

config :liddr, Liddr.Location.Cells,
  cell_size_deg: parse_float_env.(System.get_env("RIDE_SUPPLY_CELL_SIZE_DEG"), 0.01, 0.001, 0.1)

config :liddr, Liddr.Location.SupplyIndex,
  zone_ttl_seconds:
    parse_int_env.(System.get_env("RIDE_SUPPLY_ZONE_TTL_SECONDS"), 180, 30, 86_400),
  driver_ttl_seconds:
    parse_int_env.(System.get_env("RIDE_SUPPLY_DRIVER_TTL_SECONDS"), 180, 30, 86_400),
  lookup_cell_limit:
    parse_int_env.(System.get_env("RIDE_SUPPLY_LOOKUP_CELL_LIMIT"), 225, 9, 2_500)

config :liddr, Liddr.Auth.ChallengeRateLimiter,
  cooldown_seconds: parse_int_env.(System.get_env("AUTH_CHALLENGE_COOLDOWN_SECONDS"), 30, 1, 900),
  identity_window_seconds:
    parse_int_env.(System.get_env("AUTH_CHALLENGE_IDENTITY_WINDOW_SECONDS"), 900, 60, 86_400),
  identity_max_requests:
    parse_int_env.(System.get_env("AUTH_CHALLENGE_IDENTITY_MAX_REQUESTS"), 5, 1, 500),
  ip_window_seconds:
    parse_int_env.(System.get_env("AUTH_CHALLENGE_IP_WINDOW_SECONDS"), 900, 60, 86_400),
  ip_max_requests:
    parse_int_env.(System.get_env("AUTH_CHALLENGE_IP_MAX_REQUESTS"), 60, 1, 10_000),
  device_window_seconds:
    parse_int_env.(System.get_env("AUTH_CHALLENGE_DEVICE_WINDOW_SECONDS"), 900, 60, 86_400),
  device_max_requests:
    parse_int_env.(System.get_env("AUTH_CHALLENGE_DEVICE_MAX_REQUESTS"), 40, 1, 10_000)

parse_csv_env = fn value ->
  case value do
    nil ->
      []

    binary when is_binary(binary) ->
      binary
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    _ ->
      []
  end
end

config :liddr, Liddr.Subscriptions.ReconciliationPolicy,
  limit: parse_int_env.(System.get_env("SUBSCRIPTION_RECON_LIMIT"), 50, 1, 500),
  grace_seconds:
    parse_int_env.(System.get_env("SUBSCRIPTION_RECON_GRACE_SECONDS"), 90, 0, 86_400),
  max_age_seconds:
    parse_int_env.(System.get_env("SUBSCRIPTION_RECON_MAX_AGE_SECONDS"), 1_800, 60, 172_800),
  max_attempts: parse_int_env.(System.get_env("SUBSCRIPTION_RECON_MAX_ATTEMPTS"), 8, 1, 100),
  interval_seconds:
    parse_int_env.(System.get_env("SUBSCRIPTION_RECON_INTERVAL_SECONDS"), 60, 10, 3_600),
  backoff_seconds:
    parse_backoff_env.(
      System.get_env("SUBSCRIPTION_RECON_BACKOFF_SECONDS"),
      [30, 60, 120, 180, 300]
    )

config :liddr, Liddr.Rides.Execution.GeoPolicy,
  pickup_arrival_radius_m:
    parse_int_env.(System.get_env("RIDE_PICKUP_ARRIVAL_RADIUS_M"), 120, 20, 2_000),
  dropoff_completion_radius_m:
    parse_int_env.(System.get_env("RIDE_DROPOFF_COMPLETION_RADIUS_M"), 180, 20, 2_000),
  location_freshness_seconds:
    parse_int_env.(System.get_env("RIDE_LOCATION_FRESHNESS_SECONDS"), 120, 10, 3_600),
  no_show_wait_seconds:
    parse_int_env.(System.get_env("RIDE_NO_SHOW_WAIT_SECONDS"), 300, 30, 3_600),
  require_geofence_on_arrive:
    parse_bool_env.(System.get_env("RIDE_REQUIRE_GEOFENCE_ON_ARRIVE"), true),
  require_geofence_on_complete:
    parse_bool_env.(System.get_env("RIDE_REQUIRE_GEOFENCE_ON_COMPLETE"), true)

config :liddr, Liddr.Rides.Integrity.Policy,
  rolling_window_days:
    parse_int_env.(System.get_env("RIDE_INTEGRITY_ROLLING_WINDOW_DAYS"), 7, 1, 60),
  rider_chargeable_threshold:
    parse_int_env.(System.get_env("RIDE_INTEGRITY_RIDER_CHARGEABLE_THRESHOLD"), 5, 1, 20),
  rider_chargeable_escalation_threshold:
    parse_int_env.(
      System.get_env("RIDE_INTEGRITY_RIDER_CHARGEABLE_ESCALATION_THRESHOLD"),
      8,
      1,
      30
    ),
  rider_prepay_only_days:
    parse_int_env.(System.get_env("RIDE_INTEGRITY_RIDER_PREPAY_ONLY_DAYS"), 7, 1, 60),
  rider_prepay_only_escalation_days:
    parse_int_env.(
      System.get_env("RIDE_INTEGRITY_RIDER_PREPAY_ONLY_ESCALATION_DAYS"),
      14,
      1,
      90
    ),
  driver_chargeable_threshold:
    parse_int_env.(System.get_env("RIDE_INTEGRITY_DRIVER_CHARGEABLE_THRESHOLD"), 5, 1, 20),
  driver_chargeable_escalation_threshold:
    parse_int_env.(
      System.get_env("RIDE_INTEGRITY_DRIVER_CHARGEABLE_ESCALATION_THRESHOLD"),
      8,
      1,
      30
    ),
  driver_temp_suspension_days:
    parse_int_env.(System.get_env("RIDE_INTEGRITY_DRIVER_TEMP_SUSPENSION_DAYS"), 1, 1, 60),
  driver_temp_suspension_escalation_days:
    parse_int_env.(
      System.get_env("RIDE_INTEGRITY_DRIVER_TEMP_SUSPENSION_ESCALATION_DAYS"),
      3,
      1,
      90
    ),
  rider_free_cancel_grace_seconds:
    parse_int_env.(
      System.get_env("RIDE_INTEGRITY_RIDER_FREE_CANCEL_GRACE_SECONDS"),
      120,
      0,
      1_800
    ),
  rider_driver_late_waiver_seconds:
    parse_int_env.(
      System.get_env("RIDE_INTEGRITY_RIDER_DRIVER_LATE_WAIVER_SECONDS"),
      300,
      0,
      7_200
    ),
  rider_driver_location_stale_seconds:
    parse_int_env.(
      System.get_env("RIDE_INTEGRITY_RIDER_DRIVER_LOCATION_STALE_SECONDS"),
      120,
      10,
      3_600
    ),
  rider_no_progress_elapsed_seconds:
    parse_int_env.(
      System.get_env("RIDE_INTEGRITY_RIDER_NO_PROGRESS_ELAPSED_SECONDS"),
      180,
      10,
      7_200
    ),
  rider_no_progress_delta_m:
    parse_int_env.(System.get_env("RIDE_INTEGRITY_RIDER_NO_PROGRESS_DELTA_M"), 100, 10, 5_000),
  rider_moving_away_elapsed_seconds:
    parse_int_env.(
      System.get_env("RIDE_INTEGRITY_RIDER_MOVING_AWAY_ELAPSED_SECONDS"),
      120,
      10,
      7_200
    ),
  rider_moving_away_delta_m:
    parse_int_env.(System.get_env("RIDE_INTEGRITY_RIDER_MOVING_AWAY_DELTA_M"), 300, 10, 5_000),
  rider_pickup_far_distance_m:
    parse_int_env.(
      System.get_env("RIDE_INTEGRITY_RIDER_PICKUP_FAR_DISTANCE_M"),
      2_000,
      100,
      20_000
    ),
  rider_prepay_payment_mode:
    System.get_env("RIDE_INTEGRITY_RIDER_PREPAY_PAYMENT_MODE") || "in_app_mpesa",
  pickup_auto_reassign_enabled:
    parse_bool_env.(System.get_env("RIDE_PICKUP_AUTO_REASSIGN_ENABLED"), true),
  pickup_auto_reassign_after_seconds:
    parse_int_env.(System.get_env("RIDE_PICKUP_AUTO_REASSIGN_AFTER_SECONDS"), 420, 60, 7_200),
  pickup_auto_cancel_enabled:
    parse_bool_env.(System.get_env("RIDE_PICKUP_AUTO_CANCEL_ENABLED"), true),
  pickup_auto_cancel_after_seconds:
    parse_int_env.(System.get_env("RIDE_PICKUP_AUTO_CANCEL_AFTER_SECONDS"), 900, 120, 21_600),
  pickup_auto_cancel_min_reassign_count:
    parse_int_env.(System.get_env("RIDE_PICKUP_AUTO_CANCEL_MIN_REASSIGN_COUNT"), 1, 0, 10),
  pickup_watchdog_limit:
    parse_int_env.(System.get_env("RIDE_PICKUP_WATCHDOG_LIMIT"), 100, 1, 1_000)

config :liddr, Liddr.Rides.SharedRides.DetourGuard,
  max_extra_detour_m:
    parse_float_env.(System.get_env("RIDE_SHARED_MAX_EXTRA_DETOUR_M"), 2_000.0, 100.0, 20_000.0),
  max_extra_detour_ratio:
    parse_float_env.(
      System.get_env("RIDE_SHARED_MAX_EXTRA_DETOUR_RATIO"),
      0.6,
      0.05,
      5.0
    )

config :liddr, Liddr.Rides.SharedRides.StopEta,
  google_enabled: parse_bool_env.(System.get_env("RIDE_SHARED_ETA_GOOGLE_ENABLED"), false),
  fallback_speed_kph:
    parse_float_env.(System.get_env("RIDE_SHARED_ETA_FALLBACK_SPEED_KPH"), 28.0, 5.0, 120.0),
  min_leg_seconds:
    parse_int_env.(System.get_env("RIDE_SHARED_ETA_MIN_LEG_SECONDS"), 60, 5, 3_600),
  max_leg_seconds:
    parse_int_env.(System.get_env("RIDE_SHARED_ETA_MAX_LEG_SECONDS"), 7_200, 60, 21_600)

config :liddr, Liddr.Rides.SharedRides.LocationEtaRefresh,
  min_interval_seconds:
    parse_int_env.(
      System.get_env("RIDE_SHARED_ETA_REFRESH_MIN_INTERVAL_SECONDS"),
      15,
      1,
      300
    )

config :liddr, Liddr.Rides.PushClient.FCM,
  timeout_ms: parse_int_env.(System.get_env("FCM_TIMEOUT_MS"), 10_000, 1_000, 60_000)

config :liddr, Liddr.Ratings.Policy,
  rating_window_hours: parse_int_env.(System.get_env("RATING_WINDOW_HOURS"), 24, 1, 168),
  rating_decay_per_day: parse_float_env.(System.get_env("RATING_DECAY_PER_DAY"), 0.01, 0.0, 2.0),
  smoothing_prior_mean:
    parse_float_env.(System.get_env("RATING_SMOOTHING_PRIOR_MEAN"), 4.8, 1.0, 5.0),
  smoothing_prior_weight:
    parse_int_env.(System.get_env("RATING_SMOOTHING_PRIOR_WEIGHT"), 20, 0, 1000),
  enforcement_recent_window_days:
    parse_int_env.(System.get_env("RATING_ENFORCEMENT_RECENT_WINDOW_DAYS"), 30, 1, 365),
  enforcement_min_recent_ratings:
    parse_int_env.(System.get_env("RATING_ENFORCEMENT_MIN_RECENT_RATINGS"), 20, 1, 1000),
  non_attributable_reason_tags:
    parse_csv_env.(
      System.get_env("RATING_NON_ATTRIBUTABLE_REASON_TAGS") ||
        "traffic,app_issue,gps_issue,wrong_pickup_pin,co_rider_behavior"
    )

if config_env() != :test do
  config :liddr, :auth_debug_otp, parse_bool_env.(System.get_env("AUTH_DEBUG_OTP"), false)

  config :liddr, :auth_debug_otp_targets, parse_csv_env.(System.get_env("AUTH_DEBUG_OTP_TARGETS"))
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :liddr, Liddr.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :liddr, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :liddr, LiddrWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :liddr, LiddrWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :liddr, LiddrWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :liddr, Liddr.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
