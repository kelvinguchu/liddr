defmodule Liddr.Google.ServiceAccount do
  @token_url "https://oauth2.googleapis.com/token"
  @default_token_ttl_seconds 3_600

  def credentials do
    with {:ok, json} <- service_account_json(),
         {:ok, decoded} <- Jason.decode(json),
         {:ok, client_email} <- fetch_map(decoded, "client_email"),
         {:ok, private_key_pem} <- fetch_map(decoded, "private_key"),
         {:ok, private_key} <- decode_private_key(private_key_pem) do
      {:ok, %{client_email: client_email, private_key: private_key}}
    end
  end

  def oauth_access_token(scope, opts \\ [])

  def oauth_access_token(scope, opts) when is_binary(scope) do
    now = Keyword.get(opts, :now, DateTime.utc_now() |> DateTime.truncate(:second))
    token_ttl = Keyword.get(opts, :token_ttl_seconds, @default_token_ttl_seconds)

    with {:ok, creds} <- credentials(),
         {:ok, assertion} <- build_assertion(creds, scope, now, token_ttl),
         {:ok, token} <- exchange_assertion(assertion) do
      {:ok, token}
    end
  end

  def oauth_access_token(_scope, _opts), do: {:error, :google_auth_invalid_scope}

  defp build_assertion(creds, scope, now, token_ttl)
       when is_integer(token_ttl) and token_ttl > 0 do
    header = %{"alg" => "RS256", "typ" => "JWT"} |> Jason.encode!() |> base64url()

    claims =
      %{
        "iss" => creds.client_email,
        "scope" => scope,
        "aud" => @token_url,
        "iat" => DateTime.to_unix(now),
        "exp" => DateTime.to_unix(now) + token_ttl
      }
      |> Jason.encode!()
      |> base64url()

    signing_input = header <> "." <> claims

    try do
      signature =
        :public_key.sign(signing_input, :sha256, creds.private_key)
        |> base64url()

      {:ok, signing_input <> "." <> signature}
    rescue
      _ -> {:error, :google_auth_signing_failed}
    end
  end

  defp build_assertion(_creds, _scope, _now, _token_ttl), do: {:error, :google_auth_invalid_ttl}

  defp exchange_assertion(assertion) do
    grant_type = "urn:ietf:params:oauth:grant-type:jwt-bearer"

    case Req.post(@token_url, form: [grant_type: grant_type, assertion: assertion]) do
      {:ok, %{status: 200, body: %{"access_token" => token}}}
      when is_binary(token) and token != "" ->
        {:ok, token}

      {:ok, _response} ->
        {:error, :google_auth_failed}

      {:error, _reason} ->
        {:error, :google_auth_failed}
    end
  end

  defp service_account_json do
    cond do
      path = System.get_env("GOOGLE_APPLICATION_CREDENTIALS") ->
        case File.read(path) do
          {:ok, json} -> {:ok, json}
          {:error, _} -> {:error, :gcp_credentials_unreadable}
        end

      b64 = System.get_env("GCP_SERVICE_ACCOUNT_JSON_B64") ->
        case Base.decode64(b64) do
          {:ok, json} -> {:ok, json}
          :error -> {:error, :gcp_credentials_invalid}
        end

      true ->
        {:error, :gcp_credentials_missing}
    end
  end

  defp decode_private_key(private_key_pem) do
    try do
      [entry | _] = :public_key.pem_decode(private_key_pem)
      {:ok, :public_key.pem_entry_decode(entry)}
    rescue
      _ -> {:error, :gcp_credentials_invalid}
    end
  end

  defp fetch_map(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :gcp_credentials_invalid}
    end
  end

  defp base64url(value) when is_binary(value), do: Base.url_encode64(value, padding: false)
end
