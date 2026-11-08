defmodule Liddr.Disputes.CasesSupport do
  import Ecto.Query

  alias Liddr.Moderation.Query

  @reporter_only_dispute_types ~w(safety_incident wrong_driver)

  def visible_to_reported_user(user_id) do
    dynamic(
      [r],
      r.reported_user_id == ^user_id and
        fragment(
          "NOT (? ->> 'dispute_type' = ANY(?))",
          r.metadata,
          type(^@reporter_only_dispute_types, {:array, :string})
        )
    )
  end

  def build_review_attrs(attrs, outcome, decision) do
    summary =
      attrs
      |> Query.get_value(:summary)
      |> Query.normalize_text()
      |> case do
        nil -> "Dispute resolved via ops review."
        value -> value
      end

    with {:ok, amount} <- parse_resolution_amount(attrs, outcome) do
      {:ok,
       %{
         "decision" => decision,
         "reason_code" => "dispute_#{outcome}",
         "notes" => summary,
         "metadata" => %{
           "dispute_resolution" => %{
             "outcome" => outcome,
             "amount_kes" => amount
           }
         }
       }}
    end
  end

  def parse_positive_integer(value, _error_reason) when is_integer(value) and value > 0,
    do: {:ok, value}

  def parse_positive_integer(value, error_reason) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> {:error, error_reason}
    end
  end

  def parse_positive_integer(_value, error_reason), do: {:error, error_reason}

  defp parse_resolution_amount(attrs, outcome)
       when outcome in ["refund_partial", "credit_note"] do
    amount = Query.get_value(attrs, :resolution_amount_kes)

    case parse_positive_decimal(amount) do
      {:ok, decimal} -> {:ok, decimal}
      :error -> {:error, :invalid_resolution_amount}
    end
  end

  defp parse_resolution_amount(_attrs, _outcome), do: {:ok, nil}

  defp parse_positive_decimal(value) when is_integer(value) and value > 0,
    do: {:ok, Decimal.new(value)}

  defp parse_positive_decimal(value) when is_float(value) and value > 0,
    do: {:ok, Decimal.from_float(value) |> Decimal.round(2)}

  defp parse_positive_decimal(value) when is_binary(value) do
    case Decimal.parse(String.trim(value)) do
      {decimal, ""} ->
        if Decimal.compare(decimal, Decimal.new(0)) == :gt, do: {:ok, decimal}, else: :error

      _ ->
        :error
    end
  end

  defp parse_positive_decimal(_value), do: :error
end
