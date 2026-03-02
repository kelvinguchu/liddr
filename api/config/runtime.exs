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
