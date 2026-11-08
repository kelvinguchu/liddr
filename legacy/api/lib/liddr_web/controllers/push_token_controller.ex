defmodule LiddrWeb.PushTokenController do
  use LiddrWeb, :controller

  alias Ecto.Changeset
  alias Liddr.Rides.PushTokens
  alias Liddr.Rides.UserPushToken

  def upsert(conn, params) do
    user_id = conn.assigns.current_user.id

    case PushTokens.register(user_id, params) do
      {:ok, push_token} ->
        json(conn, %{data: %{push_token: token_payload(push_token)}})

      {:error, %Changeset{} = changeset} ->
        render_changeset_error(conn, changeset)

      {:error, :invalid_push_token_input} ->
        render_error(
          conn,
          :unprocessable_entity,
          "INVALID_PUSH_TOKEN",
          "Push token payload is invalid"
        )
    end
  end

  def revoke(conn, params) do
    user_id = conn.assigns.current_user.id

    case PushTokens.revoke(user_id, params) do
      :ok ->
        json(conn, %{data: %{revoked: true}})

      {:error, :invalid_push_token_revoke_input} ->
        render_error(
          conn,
          :unprocessable_entity,
          "INVALID_PUSH_TOKEN_REVOKE",
          "Provide token or device_id to revoke"
        )

      {:error, :push_token_not_found} ->
        render_error(conn, :not_found, "PUSH_TOKEN_NOT_FOUND", "Push token was not found")
    end
  end

  defp token_payload(%UserPushToken{} = push_token) do
    %{
      id: push_token.id,
      provider: push_token.provider,
      platform: push_token.platform,
      device_id: push_token.device_id,
      last_seen_at: push_token.last_seen_at,
      revoked_at: push_token.revoked_at,
      inserted_at: push_token.inserted_at,
      updated_at: push_token.updated_at
    }
  end

  defp render_changeset_error(conn, changeset) do
    details = Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "VALIDATION_ERROR", message: "Validation failed", details: details}})
  end

  defp render_error(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end
