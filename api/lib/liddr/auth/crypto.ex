defmodule Liddr.Auth.Crypto do
  alias Liddr.Auth.Input

  @access_ttl_seconds 900
  @refresh_ttl_seconds 2_592_000

  def access_ttl_seconds, do: @access_ttl_seconds
  def refresh_ttl_seconds, do: @refresh_ttl_seconds

  def build_secret_payload(method, attrs) do
    secret =
      attrs
      |> Input.get_value(:secret)
      |> Input.to_string_or_nil()

    if method in ~w(email_password totp) do
      if is_nil(secret) or String.trim(secret) == "" do
        {:error, :missing_secret}
      else
        {:ok, hash_secret(secret)}
      end
    else
      {:ok, %{secret_hash: nil, secret_salt: nil}}
    end
  end

  def hash_secret(secret) do
    salt_binary = :crypto.strong_rand_bytes(16)
    hash_binary = :crypto.pbkdf2_hmac(:sha256, secret, salt_binary, 120_000, 32)

    %{
      secret_hash: Base.encode16(hash_binary, case: :lower),
      secret_salt: Base.encode64(salt_binary)
    }
  end

  def generate_otp_code do
    (:rand.uniform(1_000_000) - 1)
    |> Integer.to_string()
    |> String.pad_leading(6, "0")
  end

  def otp_hash(code) do
    pepper =
      System.get_env("AUTH_OTP_PEPPER") ||
        System.get_env("SECRET_KEY_BASE") ||
        "liddr-dev-otp-pepper"

    :crypto.hash(:sha256, "#{code}:#{pepper}")
    |> Base.encode16(case: :lower)
  end

  def maybe_debug_code(code) do
    if Application.get_env(:liddr, :auth_debug_otp, false), do: code, else: nil
  end

  def maybe_debug_code(code, identifier) do
    if Application.get_env(:liddr, :auth_debug_otp, false) and
         debug_identifier_allowed?(identifier) do
      code
    else
      nil
    end
  end

  def token_value do
    :crypto.strong_rand_bytes(32)
    |> Base.url_encode64(padding: false)
  end

  def token_hash(token) do
    :crypto.hash(:sha256, token)
    |> Base.encode16(case: :lower)
  end

  defp debug_identifier_allowed?(identifier) when is_binary(identifier) do
    targets =
      Application.get_env(:liddr, :auth_debug_otp_targets, [])
      |> Enum.filter(&is_binary/1)

    targets == [] or identifier in targets
  end

  defp debug_identifier_allowed?(_identifier), do: false
end
