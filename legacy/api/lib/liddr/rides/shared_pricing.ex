defmodule Liddr.Rides.SharedPricing do
  @moduledoc false

  alias Decimal, as: D
  alias Liddr.Rides.VehicleCategory
  alias Liddr.Subscriptions.PaymentUtils

  @defaults %{
    base_discount_percent: 8.0,
    eta_weight_per_min: 0.9,
    detour_weight_per_km: 2.0,
    min_discount_percent: 5.0,
    max_discount_percent: 20.0,
    expected_extra_eta_min: 2.0,
    expected_extra_detour_km: 0.8,
    min_fare_floor_ratio: 0.8,
    driver_viability_multiplier: 1.05
  }

  def apply_to_pricing(%VehicleCategory{} = category, pricing, attrs \\ %{}) do
    policy = policy()
    solo_fare = to_decimal(pricing.final_fare_kes)

    extra_eta_min =
      attrs
      |> PaymentUtils.get_value(:shared_extra_eta_min)
      |> to_float_or_default(policy.expected_extra_eta_min)

    extra_detour_km =
      attrs
      |> PaymentUtils.get_value(:shared_extra_detour_km)
      |> to_float_or_default(policy.expected_extra_detour_km)

    raw_discount_percent =
      policy.base_discount_percent + policy.eta_weight_per_min * extra_eta_min +
        policy.detour_weight_per_km * extra_detour_km

    discount_percent =
      raw_discount_percent
      |> clamp(policy.min_discount_percent, policy.max_discount_percent)
      |> float_to_decimal()

    min_floor_fare =
      category.min_fare_kes
      |> D.mult(float_to_decimal(policy.min_fare_floor_ratio))
      |> round_to_nearest_ten()

    discounted_candidate =
      solo_fare
      |> D.mult(discount_multiplier(discount_percent))
      |> round_to_nearest_ten()

    shared_fare =
      discounted_candidate
      |> max_decimal(min_floor_fare)
      |> D.round(2)

    discount_amount =
      solo_fare
      |> D.sub(shared_fare)
      |> max_decimal(D.new("0.00"))
      |> D.round(2)

    effective_discount_percent =
      if D.compare(solo_fare, D.new("0")) == :gt do
        discount_amount
        |> D.mult(D.new("100"))
        |> D.div(solo_fare)
        |> D.round(2)
      else
        D.new("0.00")
      end

    adjusted_pricing =
      pricing
      |> Map.put(:discount_percent, effective_discount_percent)
      |> Map.put(:discount_amount_kes, discount_amount)
      |> Map.put(:final_fare_kes, shared_fare)

    metadata = %{
      "enabled" => true,
      "solo_fare_kes" => decimal_to_string(solo_fare),
      "shared_fare_kes" => decimal_to_string(shared_fare),
      "discount_percent" => decimal_to_string(effective_discount_percent),
      "discount_amount_kes" => decimal_to_string(discount_amount),
      "inputs" => %{
        "extra_eta_min" => extra_eta_min,
        "extra_detour_km" => extra_detour_km
      },
      "bounds" => %{
        "min_discount_percent" => policy.min_discount_percent,
        "max_discount_percent" => policy.max_discount_percent
      },
      "min_floor_fare_kes" => decimal_to_string(min_floor_fare),
      "driver_viability_multiplier" => policy.driver_viability_multiplier
    }

    %{pricing: adjusted_pricing, metadata: metadata}
  end

  defp policy do
    config = Application.get_env(:liddr, __MODULE__, [])

    %{
      base_discount_percent:
        get_number(config, :base_discount_percent, @defaults.base_discount_percent),
      eta_weight_per_min: get_number(config, :eta_weight_per_min, @defaults.eta_weight_per_min),
      detour_weight_per_km:
        get_number(config, :detour_weight_per_km, @defaults.detour_weight_per_km),
      min_discount_percent:
        get_number(config, :min_discount_percent, @defaults.min_discount_percent),
      max_discount_percent:
        get_number(config, :max_discount_percent, @defaults.max_discount_percent),
      expected_extra_eta_min:
        get_number(config, :expected_extra_eta_min, @defaults.expected_extra_eta_min),
      expected_extra_detour_km:
        get_number(config, :expected_extra_detour_km, @defaults.expected_extra_detour_km),
      min_fare_floor_ratio:
        get_number(config, :min_fare_floor_ratio, @defaults.min_fare_floor_ratio),
      driver_viability_multiplier:
        get_number(config, :driver_viability_multiplier, @defaults.driver_viability_multiplier)
    }
  end

  defp get_number(config, key, default) do
    case Keyword.get(config, key, default) do
      value when is_integer(value) -> value * 1.0
      value when is_float(value) -> value
      _ -> default
    end
  end

  defp clamp(value, min, _max) when value < min, do: min
  defp clamp(value, _min, max) when value > max, do: max
  defp clamp(value, _min, _max), do: value

  defp discount_multiplier(discount_percent),
    do: D.sub(D.new("1.00"), D.div(discount_percent, D.new("100")))

  defp float_to_decimal(value), do: D.from_float(value) |> D.round(4)
  defp to_decimal(%D{} = value), do: D.round(value, 2)
  defp to_decimal(value) when is_integer(value), do: D.new(value)
  defp to_decimal(value) when is_float(value), do: D.from_float(value) |> D.round(2)
  defp to_decimal(value) when is_binary(value), do: parse_decimal(value)
  defp to_decimal(_value), do: D.new("0.00")

  defp parse_decimal(value) do
    case D.parse(String.trim(value)) do
      {decimal, ""} -> D.round(decimal, 2)
      _ -> D.new("0.00")
    end
  end

  defp to_float_or_default(value, _default) when is_float(value), do: value
  defp to_float_or_default(value, _default) when is_integer(value), do: value * 1.0

  defp to_float_or_default(value, default) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end

  defp to_float_or_default(_value, default), do: default

  defp round_to_nearest_ten(value) do
    value
    |> D.div(D.new(10))
    |> D.round(0, :half_up)
    |> D.mult(D.new(10))
    |> D.round(2)
  end

  defp max_decimal(left, right) do
    if D.compare(left, right) == :lt, do: right, else: left
  end

  defp decimal_to_string(%D{} = value), do: D.to_string(D.round(value, 2))
end
