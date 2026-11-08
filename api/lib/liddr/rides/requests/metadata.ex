defmodule Liddr.Rides.Requests.Metadata do
  @moduledoc false

  alias Liddr.Rides.ProductType
  alias Liddr.Rides.RideQuote

  def build(quote, requested_payment_mode, metadata_overrides, shared_match_metadata) do
    quote
    |> base_metadata(requested_payment_mode)
    |> merge_metadata_overrides(metadata_overrides)
    |> maybe_put_shared_match(shared_match_metadata)
  end

  defp base_metadata(nil, nil), do: %{}

  defp base_metadata(%RideQuote{} = quote, requested_payment_mode) do
    quote_product_type = ProductType.from_quote_payload(quote.provider_payload)

    base = %{
      "quote_id" => quote.id,
      "quoted_product_type" => quote_product_type,
      "quote_expires_at" => quote.expires_at,
      "quoted_final_fare_kes" => quote.final_fare_kes,
      "quoted_distance_m" => quote.distance_m,
      "quoted_duration_s" => quote.duration_s
    }

    if is_binary(requested_payment_mode),
      do: Map.put(base, "requested_payment_mode", requested_payment_mode),
      else: base
  end

  defp merge_metadata_overrides(base, overrides) do
    Enum.reduce(overrides, base, fn {key, value}, acc ->
      if Map.has_key?(acc, key), do: acc, else: Map.put(acc, key, value)
    end)
  end

  defp maybe_put_shared_match(metadata, nil), do: metadata

  defp maybe_put_shared_match(metadata, shared_match) when is_map(shared_match) do
    if Map.has_key?(metadata, "shared_match") do
      metadata
    else
      Map.put(metadata, "shared_match", shared_match)
    end
  end

  defp maybe_put_shared_match(metadata, _shared_match), do: metadata
end
