defmodule Liddr.Payments.Mpesa.Client.Error do
  def http(operation, status, body) do
    {:mpesa_http_error, operation, status, normalize_body(body)}
  end

  def invalid_response(operation, status, body) do
    {:mpesa_invalid_response, operation, status, normalize_body(body)}
  end

  def transport(operation, reason) do
    {:mpesa_transport_error, operation, normalize_reason(reason)}
  end

  defp normalize_body(body) when is_map(body), do: body

  defp normalize_body(body) when is_binary(body) do
    if String.length(body) > 2_000, do: String.slice(body, 0, 2_000), else: body
  end

  defp normalize_body(body), do: inspect(body)

  defp normalize_reason(reason) do
    if is_exception(reason), do: Exception.message(reason), else: inspect(reason)
  end
end
