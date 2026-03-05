defmodule Liddr.Rides.ProductType do
  @moduledoc false

  alias Liddr.Subscriptions.PaymentUtils

  @types ~w(solo shared)

  def resolve(attrs, default \\ "solo") do
    value =
      attrs
      |> PaymentUtils.get_value(:product_type)
      |> PaymentUtils.normalize_text()

    cond do
      is_nil(value) -> {:ok, default}
      value in @types -> {:ok, value}
      true -> {:error, :invalid_product_type}
    end
  end

  def from_quote_payload(%{} = provider_payload) do
    case Map.get(provider_payload, "product_type") do
      value when value in @types -> value
      _ -> "solo"
    end
  end

  def from_quote_payload(_payload), do: "solo"
end
