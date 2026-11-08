defmodule Liddr.Auth.Google do
  @tokeninfo_url "https://oauth2.googleapis.com/tokeninfo"
  @default_issuers MapSet.new(["accounts.google.com", "https://accounts.google.com"])

  def verify_id_token(id_token) when is_binary(id_token) do
    token = String.trim(id_token)

    if token == "" do
      {:error, :missing_google_id_token}
    else
      with {:ok, response} <- fetch_tokeninfo(token),
           :ok <- validate_audience(response),
           :ok <- validate_issuer(response),
           :ok <- validate_expiration(response),
           {:ok, subject} <- fetch_subject(response) do
        {:ok,
         %{
           subject: subject,
           email: normalize_email(Map.get(response, "email")),
           email_verified: truthy?(Map.get(response, "email_verified"))
         }}
      end
    end
  end

  def verify_id_token(_), do: {:error, :missing_google_id_token}

  defp fetch_tokeninfo(id_token) do
    case Req.get(@tokeninfo_url, params: [id_token: id_token]) do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %{status: _status}} -> {:error, :invalid_google_id_token}
      {:error, _reason} -> {:error, :google_auth_unavailable}
    end
  end

  defp fetch_subject(response) do
    case Map.get(response, "sub") do
      sub when is_binary(sub) ->
        trimmed = String.trim(sub)
        if trimmed == "", do: {:error, :invalid_google_id_token}, else: {:ok, trimmed}

      _ ->
        {:error, :invalid_google_id_token}
    end
  end

  defp validate_audience(response) do
    audience = Map.get(response, "aud")
    allowed = allowed_google_client_ids()

    cond do
      audience in [nil, ""] ->
        {:error, :invalid_google_id_token}

      allowed == [] ->
        {:error, :missing_google_client_id}

      audience in allowed ->
        :ok

      true ->
        {:error, :google_audience_mismatch}
    end
  end

  defp validate_issuer(response) do
    issuer = Map.get(response, "iss")

    if is_binary(issuer) and MapSet.member?(allowed_google_issuers(), issuer) do
      :ok
    else
      {:error, :invalid_google_issuer}
    end
  end

  defp validate_expiration(response) do
    now_unix = DateTime.utc_now() |> DateTime.to_unix()

    with exp when not is_nil(exp) <- parse_integer(Map.get(response, "exp")),
         true <- exp > now_unix do
      :ok
    else
      _ -> {:error, :google_id_token_expired}
    end
  end

  defp allowed_google_client_ids do
    ids =
      (System.get_env("GOOGLE_CLIENT_IDS_ALLOWED") || "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case System.get_env("GOOGLE_CLIENT_ID_WEB") do
      nil -> ids
      value -> [String.trim(value) | ids]
    end
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp allowed_google_issuers do
    raw = System.get_env("GOOGLE_IDTOKEN_ISSUERS")

    if is_binary(raw) and String.trim(raw) != "" do
      raw
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> MapSet.new()
    else
      @default_issuers
    end
  end

  defp truthy?(value) when value in [true, "true", 1, "1"], do: true
  defp truthy?(_), do: false

  defp normalize_email(value) when is_binary(value) do
    trimmed = value |> String.trim() |> String.downcase()
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_email(_), do: nil

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_integer(_), do: nil
end
