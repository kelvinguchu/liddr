defmodule Liddr.Auth.Input do
  alias Liddr.Auth.Methods

  def fetch_method(attrs) do
    method =
      attrs
      |> get_value(:method)
      |> to_string_or_nil()
      |> normalize_text()

    if method in Methods.registration_methods() do
      {:ok, method}
    else
      {:error, :invalid_method}
    end
  end

  def fetch_identifier(attrs) do
    attrs
    |> get_value(:identifier)
    |> to_string_or_nil()
    |> normalize_text()
    |> case do
      nil -> {:error, :missing_identifier}
      identifier -> {:ok, identifier}
    end
  end

  def fetch_challenge_id(attrs) do
    case get_value(attrs, :challenge_id) do
      nil -> {:error, :missing_challenge_id}
      value -> {:ok, value}
    end
  end

  def fetch_code(attrs) do
    attrs
    |> get_value(:code)
    |> to_string_or_nil()
    |> normalize_text()
    |> case do
      nil -> {:error, :missing_code}
      code -> {:ok, code}
    end
  end

  def fetch_challenge_purpose(attrs) do
    purpose =
      attrs
      |> get_value(:purpose)
      |> to_string_or_nil()
      |> normalize_text()
      |> case do
        nil -> "login"
        value -> value
      end

    if purpose in Methods.challenge_purposes() do
      {:ok, purpose}
    else
      {:error, :invalid_purpose}
    end
  end

  def fetch_refresh_token(attrs) do
    attrs
    |> get_value(:refresh_token)
    |> to_string_or_nil()
    |> normalize_text()
    |> case do
      nil -> {:error, :missing_refresh_token}
      token -> {:ok, token}
    end
  end

  def normalize_identifier_for_method(method, identifier) do
    normalize_identifier(method, identifier)
  end

  def get_value(attrs, key) when is_map(attrs),
    do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  def get_value(_attrs, _key), do: nil

  def to_string_or_nil(nil), do: nil
  def to_string_or_nil(value) when is_binary(value), do: value
  def to_string_or_nil(value), do: to_string(value)

  def normalize_text(nil), do: nil

  def normalize_text(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_identifier("phone_otp", identifier), do: normalize_phone(identifier)
  defp normalize_identifier("email_otp", identifier), do: normalize_email(identifier)
  defp normalize_identifier("email_password", identifier), do: normalize_email(identifier)
  defp normalize_identifier("google", identifier), do: normalize_oauth_subject(identifier)
  defp normalize_identifier("apple", identifier), do: normalize_oauth_subject(identifier)
  defp normalize_identifier("totp", identifier), do: normalize_email(identifier)
  defp normalize_identifier(_unsupported, _identifier), do: {:error, :invalid_method}

  defp normalize_phone(raw_phone) do
    digits = String.replace(raw_phone, ~r/\D/, "")

    cond do
      String.starts_with?(digits, "254") and String.length(digits) == 12 ->
        {:ok, digits}

      String.starts_with?(digits, "0") and String.length(digits) == 10 ->
        {:ok, "254" <> String.slice(digits, 1, 9)}

      String.starts_with?(digits, "7") and String.length(digits) == 9 ->
        {:ok, "254" <> digits}

      true ->
        {:error, :invalid_phone}
    end
  end

  defp normalize_email(raw_email) do
    normalized = raw_email |> String.downcase() |> String.trim()

    if String.contains?(normalized, "@") do
      {:ok, normalized}
    else
      {:error, :invalid_email}
    end
  end

  defp normalize_oauth_subject(raw_subject) do
    normalized = raw_subject |> String.trim()

    if normalized == "" do
      {:error, :invalid_identifier}
    else
      {:ok, normalized}
    end
  end
end
