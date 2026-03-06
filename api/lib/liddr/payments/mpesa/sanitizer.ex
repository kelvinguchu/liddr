defmodule Liddr.Payments.Mpesa.Sanitizer do
  @moduledoc false

  alias Liddr.Security.Redaction

  def payload(%{"Name" => name, "Value" => value} = item) when is_binary(name) do
    sanitized_value =
      %{name => payload(value)}
      |> Redaction.sanitize_payload()
      |> Map.get(name)

    Map.put(item, "Value", sanitized_value)
  end

  def payload(%{} = payload) do
    payload
    |> Enum.map(fn {key, value} -> {key, payload(value)} end)
    |> Map.new()
    |> Redaction.sanitize_payload()
  end

  def payload(payload) when is_list(payload), do: Enum.map(payload, &payload/1)
  def payload(payload), do: payload

  def query_payload(query_result, requested_at) do
    %{
      "requested_at" => requested_at,
      "request_payload" => payload(query_result.request_payload),
      "response_payload" => payload(query_result.response_payload)
    }
  end
end
