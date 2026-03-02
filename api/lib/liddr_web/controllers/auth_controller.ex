defmodule LiddrWeb.AuthController do
  use LiddrWeb, :controller

  alias Ecto.Changeset
  alias Liddr.Auth

  @error_mappings %{
    invalid_method:
      {:unprocessable_entity, "INVALID_METHOD", "Unsupported authentication method"},
    method_not_allowed_for_role:
      {:unprocessable_entity, "METHOD_NOT_ALLOWED_FOR_ROLE",
       "The chosen authentication method is not allowed for this registration track"},
    method_does_not_support_challenge:
      {:unprocessable_entity, "METHOD_DOES_NOT_SUPPORT_CHALLENGE",
       "Only OTP methods can request a challenge"},
    invalid_purpose: {:unprocessable_entity, "INVALID_PURPOSE", "Invalid auth challenge purpose"},
    challenge_rate_limited:
      {:too_many_requests, "CHALLENGE_RATE_LIMITED",
       "Please wait before requesting another challenge"},
    missing_challenge_id:
      {:unprocessable_entity, "MISSING_CHALLENGE_ID", "challenge_id is required for verification"},
    missing_code: {:unprocessable_entity, "MISSING_CODE", "code is required for verification"},
    challenge_not_found: {:not_found, "CHALLENGE_NOT_FOUND", "Challenge not found"},
    challenge_already_consumed:
      {:unprocessable_entity, "CHALLENGE_ALREADY_CONSUMED", "Challenge was already used"},
    challenge_locked: {:too_many_requests, "CHALLENGE_LOCKED", "Challenge is temporarily locked"},
    challenge_expired: {:unprocessable_entity, "CHALLENGE_EXPIRED", "Challenge has expired"},
    invalid_code: {:unauthorized, "INVALID_CODE", "Invalid OTP code"},
    identity_not_found:
      {:unauthorized, "IDENTITY_NOT_FOUND", "No account found for this authentication identity"},
    missing_refresh_token:
      {:unprocessable_entity, "MISSING_REFRESH_TOKEN", "refresh_token is required"},
    invalid_refresh_token: {:unauthorized, "INVALID_REFRESH_TOKEN", "Invalid refresh token"},
    refresh_token_revoked:
      {:unauthorized, "REFRESH_TOKEN_REVOKED", "Refresh token has been revoked"},
    refresh_token_expired: {:unauthorized, "REFRESH_TOKEN_EXPIRED", "Refresh token has expired"},
    refresh_token_reuse_detected:
      {:unauthorized, "REFRESH_TOKEN_REUSE_DETECTED",
       "Refresh token reuse detected. Please sign in again"},
    session_not_found: {:not_found, "SESSION_NOT_FOUND", "Session not found"},
    user_not_found: {:not_found, "USER_NOT_FOUND", "User not found"},
    account_suspended: {:forbidden, "ACCOUNT_SUSPENDED", "This account is currently suspended"},
    account_banned: {:forbidden, "ACCOUNT_BANNED", "This account has been permanently banned"},
    account_deactivated: {:forbidden, "ACCOUNT_DEACTIVATED", "This account has been deactivated"},
    missing_identifier:
      {:unprocessable_entity, "MISSING_IDENTIFIER",
       "An identifier is required (phone, email, or provider subject)"},
    invalid_identifier:
      {:unprocessable_entity, "INVALID_IDENTIFIER", "Invalid identifier format"},
    invalid_phone:
      {:unprocessable_entity, "INVALID_PHONE",
       "Invalid phone format. Use a Kenyan number such as 07XXXXXXXX"},
    invalid_email: {:unprocessable_entity, "INVALID_EMAIL", "Invalid email format"},
    missing_secret:
      {:unprocessable_entity, "MISSING_SECRET",
       "Secret is required for this authentication method"},
    missing_google_id_token:
      {:unprocessable_entity, "MISSING_GOOGLE_ID_TOKEN", "Google ID token is required in secret"},
    missing_google_client_id:
      {:unprocessable_entity, "MISSING_GOOGLE_CLIENT_ID",
       "Google client ID is not configured on server"},
    google_audience_mismatch:
      {:unprocessable_entity, "GOOGLE_AUDIENCE_MISMATCH",
       "Google ID token audience does not match configured client ID"},
    invalid_google_issuer:
      {:unprocessable_entity, "INVALID_GOOGLE_ISSUER", "Google ID token issuer is invalid"},
    google_id_token_expired:
      {:unprocessable_entity, "GOOGLE_ID_TOKEN_EXPIRED", "Google ID token has expired"},
    invalid_google_id_token:
      {:unprocessable_entity, "INVALID_GOOGLE_ID_TOKEN", "Google ID token is invalid"},
    google_auth_unavailable:
      {:service_unavailable, "GOOGLE_AUTH_UNAVAILABLE",
       "Google token verification is temporarily unavailable"}
  }

  def methods(conn, _params) do
    json(conn, %{data: %{methods: Auth.supported_methods()}})
  end

  def register_rider(conn, params) do
    Auth.register_rider(params)
    |> handle_result(conn, :created)
  end

  def register_driver(conn, params) do
    Auth.register_driver(params)
    |> handle_result(conn, :created)
  end

  def challenge(conn, params) do
    Auth.request_challenge(params, request_meta(conn))
    |> handle_result(conn, :created)
  end

  def verify_challenge(conn, params) do
    Auth.verify_challenge(params, request_meta(conn))
    |> handle_result(conn, :ok)
  end

  def refresh(conn, params) do
    Auth.refresh_session(params, request_meta(conn))
    |> handle_result(conn, :ok)
  end

  def logout(conn, params) do
    Auth.logout(params)
    |> handle_result(conn, :ok)
  end

  defp render_error(conn, %Changeset{} = changeset) do
    details = Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        code: "VALIDATION_ERROR",
        message: "Validation failed",
        details: details
      }
    })
  end

  defp render_error(conn, reason) when is_atom(reason) do
    case Map.get(@error_mappings, reason) do
      {status, code, message} ->
        error_response(conn, status, code, message)

      nil ->
        error_response(
          conn,
          :unprocessable_entity,
          "AUTH_ERROR",
          "Unable to complete authentication request"
        )
    end
  end

  defp render_error(conn, _unknown) do
    error_response(
      conn,
      :unprocessable_entity,
      "AUTH_ERROR",
      "Unable to complete authentication request"
    )
  end

  defp request_meta(conn) do
    %{
      ip: remote_ip_to_string(conn.remote_ip),
      device: List.first(get_req_header(conn, "x-device-id")),
      user_agent: List.first(get_req_header(conn, "user-agent"))
    }
  end

  defp remote_ip_to_string({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"

  defp remote_ip_to_string({a, b, c, d, e, f, g, h}),
    do: "#{a}:#{b}:#{c}:#{d}:#{e}:#{f}:#{g}:#{h}"

  defp remote_ip_to_string(_), do: nil

  defp handle_result({:ok, payload}, conn, status) do
    conn
    |> put_status(status)
    |> json(%{data: payload})
  end

  defp handle_result({:error, reason}, conn, _status), do: render_error(conn, reason)

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end
