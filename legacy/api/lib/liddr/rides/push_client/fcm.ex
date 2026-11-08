defmodule Liddr.Rides.PushClient.FCM do
  @moduledoc false

  @behaviour Liddr.Rides.PushClient

  alias Liddr.Google.ServiceAccount
  alias Liddr.Rides.PushTokens

  @oauth_scope "https://www.googleapis.com/auth/firebase.messaging"
  @default_timeout_ms 10_000

  @impl Liddr.Rides.PushClient
  def send_ride_notification(%{} = payload) do
    with {:ok, recipient_user_id} <- fetch_recipient_user_id(payload),
         {:ok, project_id} <- fetch_project_id(),
         {:ok, access_token} <- ServiceAccount.oauth_access_token(@oauth_scope),
         tokens when is_list(tokens) <- PushTokens.list_active_tokens_for_user(recipient_user_id),
         :ok <- ensure_tokens_present(tokens),
         :ok <- deliver(tokens, project_id, access_token, payload) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :push_delivery_failed}
    end
  end

  def send_ride_notification(_payload), do: {:error, :invalid_push_payload}

  defp deliver(tokens, project_id, access_token, payload) do
    url = "https://fcm.googleapis.com/v1/projects/#{project_id}/messages:send"
    timeout_ms = fcm_timeout_ms()

    results =
      Enum.map(tokens, fn token ->
        body = %{"message" => %{"token" => token, "data" => build_data(payload)}}

        case Req.post(url,
               headers: [
                 {"authorization", "Bearer " <> access_token},
                 {"content-type", "application/json"}
               ],
               json: body,
               receive_timeout: timeout_ms
             ) do
          {:ok, %{status: status}} when status in 200..299 ->
            :ok

          {:ok, %{status: status, body: body}} ->
            maybe_revoke_invalid_token(token, status, body)
            {:error, {:fcm_http_error, status}}

          {:error, _reason} ->
            {:error, :fcm_transport_error}
        end
      end)

    if Enum.any?(results, &(&1 == :ok)) do
      :ok
    else
      {:error, :push_delivery_failed}
    end
  end

  defp build_data(payload) do
    %{
      "event_type" =>
        to_string(Map.get(payload, :event_type) || Map.get(payload, "event_type") || ""),
      "ride_id" => to_string(Map.get(payload, :ride_id) || Map.get(payload, "ride_id") || ""),
      "notification_id" =>
        to_string(Map.get(payload, :notification_id) || Map.get(payload, "notification_id") || ""),
      "payload_json" => payload |> Map.get(:payload, %{}) |> Jason.encode!()
    }
  end

  defp fetch_recipient_user_id(payload) do
    value = Map.get(payload, :recipient_user_id) || Map.get(payload, "recipient_user_id")

    if is_integer(value) and value > 0 do
      {:ok, value}
    else
      {:error, :invalid_push_payload}
    end
  end

  defp ensure_tokens_present([]), do: {:error, :push_token_not_found}
  defp ensure_tokens_present(_tokens), do: :ok

  defp fetch_project_id do
    case System.get_env("FCM_PROJECT_ID") || System.get_env("GCP_PROJECT_ID") do
      nil -> {:error, :fcm_project_id_missing}
      project_id -> {:ok, String.trim(project_id)}
    end
  end

  defp maybe_revoke_invalid_token(token, status, body) when status in [400, 404] do
    message =
      cond do
        is_map(body) -> inspect(body)
        is_binary(body) -> body
        true -> ""
      end

    if String.contains?(String.upcase(message), "UNREGISTERED") do
      _ = PushTokens.revoke_token_by_value(token)
    end
  end

  defp maybe_revoke_invalid_token(_token, _status, _body), do: :ok

  defp fcm_timeout_ms do
    case Application.get_env(:liddr, __MODULE__, [])
         |> Keyword.get(:timeout_ms, @default_timeout_ms) do
      value when is_integer(value) and value > 0 -> value
      _ -> @default_timeout_ms
    end
  end
end
