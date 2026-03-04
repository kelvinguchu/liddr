defmodule Liddr.Rides.SharedPricingTest do
  use ExUnit.Case, async: true

  alias Decimal, as: D
  alias Liddr.Rides.SharedPricing
  alias Liddr.Rides.VehicleCategory

  test "applies bounded dynamic discount and rounds to nearest ten" do
    category = %VehicleCategory{min_fare_kes: D.new("180.00")}

    pricing = %{
      final_fare_kes: D.new("230.00"),
      discount_percent: D.new("15.00"),
      discount_amount_kes: D.new("40.00")
    }

    result =
      SharedPricing.apply_to_pricing(category, pricing, %{
        "shared_extra_eta_min" => 2.0,
        "shared_extra_detour_km" => 0.8
      })

    assert D.compare(result.pricing.final_fare_kes, D.new("230.00")) == :lt
    assert D.compare(result.pricing.discount_percent, D.new("5.00")) in [:gt, :eq]
    assert D.compare(result.pricing.discount_percent, D.new("20.00")) in [:lt, :eq]

    {fare_int, ""} =
      result.pricing.final_fare_kes
      |> D.to_string()
      |> String.replace(".00", "")
      |> Integer.parse()

    assert rem(fare_int, 10) == 0
  end
end
