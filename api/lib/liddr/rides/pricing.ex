defmodule Liddr.Rides.Pricing do
  alias Decimal, as: D
  alias Liddr.Rides.VehicleCategory

  @max_surge_multiplier D.new("5.00")
  @min_surge_multiplier D.new("1.00")

  def build_breakdown(%VehicleCategory{} = category, attrs) do
    distance_m = attrs.distance_m
    duration_s = attrs.duration_s
    surge_multiplier = normalize_surge(attrs.surge_multiplier)

    distance_km = distance_m / 1000
    duration_min = duration_s / 60

    distance_amount =
      calculate_tiered_amount(
        category.price_per_km_kes,
        distance_km,
        distance_bands_for(category.slug)
      )

    time_amount =
      calculate_tiered_amount(
        category.price_per_min_kes,
        duration_min,
        time_bands_for(category.slug)
      )

    pre_min =
      category.base_fee_kes
      |> D.add(distance_amount)
      |> D.add(time_amount)

    subtotal =
      if D.compare(pre_min, category.min_fare_kes) == :lt,
        do: category.min_fare_kes,
        else: pre_min

    base_fare =
      subtotal
      |> D.mult(surge_multiplier)
      |> round_to_nearest_ten()

    discount_percent = normalize_discount_percent(category.discount_percent)
    discounted_fare = apply_discount(base_fare, discount_percent)
    discount_amount = D.sub(base_fare, discounted_fare)

    %{
      base_amount_kes: money_round(category.base_fee_kes),
      distance_amount_kes: money_round(distance_amount),
      time_amount_kes: money_round(time_amount),
      min_fare_kes: money_round(category.min_fare_kes),
      surge_multiplier: D.round(surge_multiplier, 2),
      subtotal_kes: money_round(subtotal),
      base_fare_kes: money_round(base_fare),
      discount_percent: D.round(discount_percent, 2),
      discount_amount_kes: money_round(discount_amount),
      final_fare_kes: money_round(discounted_fare)
    }
  end

  defp normalize_surge(nil), do: @min_surge_multiplier

  defp normalize_surge(value) do
    parsed =
      cond do
        is_binary(value) ->
          case D.parse(String.trim(value)) do
            {decimal, ""} -> decimal
            _ -> @min_surge_multiplier
          end

        is_integer(value) ->
          D.new(value)

        is_float(value) ->
          D.from_float(value)

        match?(%D{}, value) ->
          value

        true ->
          @min_surge_multiplier
      end

    parsed
    |> max_decimal(@min_surge_multiplier)
    |> min_decimal(@max_surge_multiplier)
  end

  defp max_decimal(left, right) do
    if D.compare(left, right) == :lt, do: right, else: left
  end

  defp min_decimal(left, right) do
    if D.compare(left, right) == :gt, do: right, else: left
  end

  defp money_round(value), do: D.round(value, 2)

  defp round_to_nearest_ten(value) do
    value
    |> D.div(D.new(10))
    |> D.round(0, :half_up)
    |> D.mult(D.new(10))
    |> D.round(2)
  end

  defp normalize_discount_percent(nil), do: D.new("0.00")

  defp normalize_discount_percent(value) do
    parsed =
      cond do
        is_binary(value) ->
          case D.parse(String.trim(value)) do
            {decimal, ""} -> decimal
            _ -> D.new("0.00")
          end

        is_integer(value) ->
          D.new(value)

        is_float(value) ->
          D.from_float(value)

        match?(%D{}, value) ->
          value

        true ->
          D.new("0.00")
      end

    parsed
    |> max_decimal(D.new("0.00"))
    |> min_decimal(D.new("100.00"))
  end

  defp apply_discount(base_fare, discount_percent) do
    multiplier = D.sub(D.new("1.00"), D.div(discount_percent, D.new("100")))

    base_fare
    |> D.mult(multiplier)
    |> round_to_nearest_ten()
  end

  defp distance_bands_for("motorbike"), do: [{4.0, "1.00"}, {12.0, "0.96"}, {:infinity, "0.92"}]

  defp distance_bands_for("electric_motorbike"),
    do: [{4.0, "1.00"}, {12.0, "0.96"}, {:infinity, "0.92"}]

  defp distance_bands_for("send"), do: [{3.0, "1.00"}, {10.0, "1.05"}, {:infinity, "1.12"}]
  defp distance_bands_for("comfort"), do: [{6.0, "1.00"}, {20.0, "0.94"}, {:infinity, "0.88"}]
  defp distance_bands_for("xl"), do: [{6.0, "1.00"}, {20.0, "1.00"}, {:infinity, "1.03"}]
  defp distance_bands_for(_slug), do: [{6.0, "1.00"}, {20.0, "0.95"}, {:infinity, "0.90"}]

  defp time_bands_for("motorbike"), do: [{20.0, "1.00"}, {45.0, "0.95"}, {:infinity, "0.90"}]

  defp time_bands_for("electric_motorbike"),
    do: [{20.0, "1.00"}, {45.0, "0.95"}, {:infinity, "0.90"}]

  defp time_bands_for("send"), do: [{20.0, "1.00"}, {45.0, "0.98"}, {:infinity, "0.95"}]
  defp time_bands_for("comfort"), do: [{20.0, "1.00"}, {50.0, "0.94"}, {:infinity, "0.88"}]
  defp time_bands_for("xl"), do: [{20.0, "1.00"}, {50.0, "1.00"}, {:infinity, "1.02"}]
  defp time_bands_for(_slug), do: [{20.0, "1.00"}, {50.0, "0.95"}, {:infinity, "0.90"}]

  defp calculate_tiered_amount(_rate, total_units, _bands) when total_units <= 0,
    do: D.new("0.00")

  defp calculate_tiered_amount(rate, total_units, bands) do
    {amount, _remaining, _consumed} =
      Enum.reduce(bands, {D.new("0.00"), total_units, 0.0}, fn {limit, factor},
                                                               {amount, remaining, consumed} ->
        if remaining <= 0 do
          {amount, 0.0, consumed}
        else
          band_capacity =
            case limit do
              :infinity -> remaining
              finite -> max(finite - consumed, 0.0)
            end

          units_in_band = min(remaining, band_capacity)

          band_amount =
            rate
            |> D.mult(D.from_float(units_in_band))
            |> D.mult(D.new(factor))

          {D.add(amount, band_amount), remaining - units_in_band, consumed + units_in_band}
        end
      end)

    amount
  end
end
