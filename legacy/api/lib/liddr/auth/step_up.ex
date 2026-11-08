defmodule Liddr.Auth.StepUp do
  @moduledoc false

  alias Liddr.Accounts.User
  alias Liddr.Auth.Challenges
  alias Liddr.Auth.Input
  alias Liddr.Auth.TotpEnrollment
  alias LiddrWeb.Endpoint

  @salt "auth_step_up"
  @default_ttl_seconds 300

  def ttl_seconds do
    Application.get_env(:liddr, __MODULE__, [])
    |> Keyword.get(:ttl_seconds, @default_ttl_seconds)
  end

  def request_challenge(%User{} = user, session_id, meta) do
    case TotpEnrollment.request_step_up_challenge(user, session_id) do
      {:ok, payload} ->
        {:ok, payload}

      {:error, :totp_not_enrolled} ->
        with {:ok, identifier} <- fetch_step_up_identifier(user) do
          Challenges.request_challenge(
            %{
              "method" => "email_otp",
              "identifier" => identifier,
              "purpose" => "step_up"
            },
            Map.merge(meta, %{current_user_id: user.id, current_session_id: session_id})
          )
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def verify_challenge(%User{} = user, session_id, attrs, meta) do
    case TotpEnrollment.verify_step_up_challenge(user, session_id, attrs) do
      {:ok, :verified} ->
        now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
        {:ok, issue_token(user.id, session_id, now)}

      {:error, :not_totp_challenge} ->
        Challenges.verify_challenge(
          attrs,
          Map.merge(meta, %{current_user_id: user.id, current_session_id: session_id})
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  def issue_token(user_id, session_id, now) do
    token =
      Phoenix.Token.sign(Endpoint, @salt, %{
        "user_id" => user_id,
        "session_id" => session_id,
        "issued_at" => DateTime.to_unix(now, :second)
      })

    %{
      token_type: "step_up",
      step_up_token: token,
      expires_in: ttl_seconds()
    }
  end

  def verify_token(token, expected_user_id, expected_session_id) when is_binary(token) do
    with {:ok, payload} <- Phoenix.Token.verify(Endpoint, @salt, token, max_age: ttl_seconds()),
         :ok <- validate_payload(payload, expected_user_id, expected_session_id) do
      :ok
    else
      {:error, :expired} -> {:error, :step_up_token_expired}
      {:error, _reason} -> {:error, :invalid_step_up_token}
    end
  end

  def verify_token(_token, _expected_user_id, _expected_session_id),
    do: {:error, :invalid_step_up_token}

  defp fetch_step_up_identifier(%User{email: email}) do
    case Input.normalize_text(email) do
      nil -> {:error, :step_up_email_required}
      identifier -> {:ok, identifier}
    end
  end

  defp validate_payload(
         %{"user_id" => user_id, "session_id" => session_id},
         expected_user_id,
         expected_session_id
       )
       when user_id == expected_user_id and session_id == expected_session_id,
       do: :ok

  defp validate_payload(_payload, _expected_user_id, _expected_session_id),
    do: {:error, :invalid_step_up_token}
end
