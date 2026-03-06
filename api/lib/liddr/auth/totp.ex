defmodule Liddr.Auth.Totp do
  @moduledoc false

  import Bitwise

  alias Plug.Crypto.KeyGenerator
  alias Plug.Crypto.MessageEncryptor

  @digits 6
  @period_seconds 30
  @secret_bytes 20
  @default_issuer "Liddr"
  @default_setup_ttl_seconds 600

  def issuer do
    Application.get_env(:liddr, __MODULE__, [])
    |> Keyword.get(:issuer, @default_issuer)
  end

  def setup_ttl_seconds do
    Application.get_env(:liddr, __MODULE__, [])
    |> Keyword.get(:setup_ttl_seconds, @default_setup_ttl_seconds)
  end

  def digits, do: @digits
  def period_seconds, do: @period_seconds

  def generate_secret do
    @secret_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.encode32(case: :upper, padding: false)
  end

  def current_code(secret, now \\ DateTime.utc_now()) do
    counter = now |> DateTime.to_unix(:second) |> div(@period_seconds)
    {:ok, normalized_secret} = normalize_secret(secret)
    generate_code(normalized_secret, counter)
  end

  def verify_code(secret, code, now \\ DateTime.utc_now(), opts \\ []) do
    with {:ok, normalized_secret} <- normalize_secret(secret),
         {:ok, normalized_code} <- normalize_code(code) do
      counter = now |> DateTime.to_unix(:second) |> div(@period_seconds)
      window = Keyword.get(opts, :window, 1)

      if Enum.any?(
           -window..window,
           &code_matches?(normalized_secret, normalized_code, counter, &1)
         ) do
        :ok
      else
        {:error, :invalid_totp_code}
      end
    end
  end

  def provisioning_uri(secret, account_name) when is_binary(account_name) do
    label = URI.encode_www_form("#{issuer()}:#{account_name}")

    query =
      URI.encode_query(%{
        "secret" => secret,
        "issuer" => issuer(),
        "algorithm" => "SHA1",
        "digits" => Integer.to_string(@digits),
        "period" => Integer.to_string(@period_seconds)
      })

    "otpauth://totp/#{label}?#{query}"
  end

  def encrypt_payload(payload, salt) when is_map(payload) and is_binary(salt) do
    with {:ok, json} <- Jason.encode(payload) do
      {:ok, MessageEncryptor.encrypt(json, aad(salt), encryption_key(salt), signing_key(salt))}
    end
  end

  def decrypt_payload(token, salt) when is_binary(token) and is_binary(salt) do
    case MessageEncryptor.decrypt(token, aad(salt), encryption_key(salt), signing_key(salt)) do
      {:ok, json} -> Jason.decode(json)
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_secret(secret) when is_binary(secret) do
    normalized =
      secret
      |> String.upcase()
      |> String.replace(~r/[\s-]/, "")

    case Base.decode32(normalized, case: :mixed, padding: false) do
      {:ok, _decoded} -> {:ok, normalized}
      :error -> {:error, :invalid_totp_secret}
    end
  end

  defp normalize_secret(_secret), do: {:error, :invalid_totp_secret}

  defp normalize_code(code) when is_binary(code) do
    normalized = String.trim(code)

    cond do
      normalized == "" -> {:error, :missing_code}
      String.match?(normalized, ~r/^\d{6}$/) -> {:ok, normalized}
      true -> {:error, :invalid_totp_code}
    end
  end

  defp normalize_code(_code), do: {:error, :invalid_totp_code}

  defp code_matches?(secret, code, counter, offset) do
    compare_counter = max(counter + offset, 0)
    generated = generate_code(secret, compare_counter)
    byte_size(generated) == byte_size(code) and Plug.Crypto.secure_compare(generated, code)
  end

  defp generate_code(secret, counter) do
    binary_secret = Base.decode32!(secret, case: :mixed, padding: false)
    message = <<counter::unsigned-big-64>>
    hmac = :crypto.mac(:hmac, :sha, binary_secret, message)
    offset = :binary.last(hmac) &&& 0x0F
    <<_::binary-size(offset), part::unsigned-big-32, _::binary>> = hmac

    rem(part &&& 0x7FFF_FFFF, 1_000_000)
    |> Integer.to_string()
    |> String.pad_leading(@digits, "0")
  end

  defp encryption_key(salt), do: derive_key("#{salt}:enc")
  defp signing_key(salt), do: derive_key("#{salt}:sign")
  defp aad(salt), do: "liddr:totp:#{salt}"

  defp derive_key(salt) do
    KeyGenerator.generate(secret_key_base(), salt, iterations: 1000, length: 32)
  end

  defp secret_key_base do
    endpoint_config = Application.fetch_env!(:liddr, LiddrWeb.Endpoint)
    endpoint_config[:secret_key_base] || System.fetch_env!("SECRET_KEY_BASE")
  end
end
