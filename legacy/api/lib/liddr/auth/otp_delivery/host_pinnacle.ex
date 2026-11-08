defmodule Liddr.Auth.OtpDelivery.HostPinnacle do
  @behaviour Liddr.Auth.OtpDelivery.SmsClient

  require Logger

  alias Liddr.Auth.Input
  alias Liddr.Auth.OtpDelivery.HostPinnacle.Config

  @impl true
  def send_otp(phone, message) when is_binary(phone) and is_binary(message) do
    with {:ok, config} <- Config.fetch(),
         {:ok, formatted_phone} <- Input.normalize_identifier_for_method("phone_otp", phone),
         {:ok, response} <- request(config, formatted_phone, message),
         :ok <- validate_provider_response(response) do
      :ok
    else
      {:error, reason} ->
        Logger.error("[auth.otp_delivery.host_pinnacle] request_failed reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  def send_otp(_phone, _message), do: {:error, :invalid_sms_payload}

  defp request(config, formatted_phone, message) do
    Req.post(config.url,
      headers: [
        {"apikey", config.api_key},
        {"cache-control", "no-cache"}
      ],
      form: %{
        "userid" => config.user_id,
        "password" => config.password,
        "senderid" => config.sender_id,
        "mobile" => formatted_phone,
        "msg" => message,
        "msgType" => "text",
        "duplicatecheck" => "true",
        "output" => "json",
        "sendMethod" => "quick"
      },
      receive_timeout: config.timeout_ms
    )
  end

  defp validate_provider_response(%{status: status, body: body})
       when status >= 200 and status < 300 do
    if provider_success?(body) do
      :ok
    else
      {:error, {:provider_rejected, extract_error(body)}}
    end
  end

  defp validate_provider_response(%{status: status, body: body}) do
    {:error, {:http_error, status, extract_error(body)}}
  end

  defp validate_provider_response({:error, reason}), do: {:error, reason}

  defp provider_success?(body) when is_map(body) do
    status =
      body
      |> Map.get("status")
      |> normalize_status()

    cond do
      status in ["success", "ok", "sent"] -> true
      Map.get(body, "success") == true -> true
      present?(Map.get(body, "msgid")) -> true
      present?(Map.get(body, "messageId")) -> true
      true -> false
    end
  end

  defp provider_success?(_body), do: false

  defp extract_error(body) when is_map(body) do
    Map.get(body, "message") ||
      Map.get(body, "error") ||
      Map.get(body, "statusDescription") ||
      inspect(body)
  end

  defp extract_error(body), do: inspect(body)

  defp normalize_status(nil), do: nil

  defp normalize_status(status) when is_binary(status) do
    status |> String.trim() |> String.downcase()
  end

  defp normalize_status(status), do: to_string(status) |> String.downcase()

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
