defmodule Liddr.Auth.OtpDelivery.Resend do
  @behaviour Liddr.Auth.OtpDelivery.EmailClient

  require Logger

  alias Liddr.Auth.OtpDelivery.Resend.Config

  @impl true
  def send_otp(email, subject, message)
      when is_binary(email) and is_binary(subject) and is_binary(message) do
    with {:ok, config} <- Config.fetch(),
         {:ok, response} <- request(config, email, subject, message),
         :ok <- validate_response(response) do
      :ok
    else
      {:error, reason} ->
        Logger.error("[auth.otp_delivery.resend] request_failed reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  def send_otp(_email, _subject, _message), do: {:error, :invalid_email_payload}

  defp request(config, email, subject, message) do
    Req.post(config.url,
      auth: {:bearer, config.api_key},
      json: %{from: config.from, to: [email], subject: subject, text: message},
      receive_timeout: config.timeout_ms,
      retry: false
    )
  end

  defp validate_response(%{status: status, body: %{"id" => id}})
       when status in 200..299 and is_binary(id) and id != "",
       do: :ok

  defp validate_response(%{status: status, body: body}) do
    {:error, {:http_error, status, error_name(body)}}
  end

  defp error_name(%{"name" => name}) when is_binary(name), do: name
  defp error_name(_body), do: "unknown"
end
