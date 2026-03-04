defmodule Liddr.Rides.RideQuote do
  use Ecto.Schema
  import Ecto.Changeset

  schema "ride_quotes" do
    field :rider_id, :id
    field :vehicle_category_id, :id
    field :pickup_lat, :decimal
    field :pickup_lng, :decimal
    field :dropoff_lat, :decimal
    field :dropoff_lng, :decimal
    field :distance_m, :integer
    field :duration_s, :integer
    field :static_duration_s, :integer
    field :base_amount_kes, :decimal
    field :distance_amount_kes, :decimal
    field :time_amount_kes, :decimal
    field :min_fare_kes, :decimal
    field :surge_multiplier, :decimal
    field :subtotal_kes, :decimal
    field :base_fare_kes, :decimal
    field :discount_percent, :decimal
    field :discount_amount_kes, :decimal
    field :final_fare_kes, :decimal
    field :currency, :string
    field :provider, :string
    field :provider_payload, :map, default: %{}
    field :expires_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(quote, attrs) do
    quote
    |> cast(attrs, [
      :rider_id,
      :vehicle_category_id,
      :pickup_lat,
      :pickup_lng,
      :dropoff_lat,
      :dropoff_lng,
      :distance_m,
      :duration_s,
      :static_duration_s,
      :base_amount_kes,
      :distance_amount_kes,
      :time_amount_kes,
      :min_fare_kes,
      :surge_multiplier,
      :subtotal_kes,
      :base_fare_kes,
      :discount_percent,
      :discount_amount_kes,
      :final_fare_kes,
      :currency,
      :provider,
      :provider_payload,
      :expires_at
    ])
    |> validate_required([
      :rider_id,
      :vehicle_category_id,
      :pickup_lat,
      :pickup_lng,
      :dropoff_lat,
      :dropoff_lng,
      :distance_m,
      :duration_s,
      :base_amount_kes,
      :distance_amount_kes,
      :time_amount_kes,
      :min_fare_kes,
      :surge_multiplier,
      :subtotal_kes,
      :base_fare_kes,
      :discount_percent,
      :discount_amount_kes,
      :final_fare_kes,
      :currency,
      :provider,
      :expires_at
    ])
    |> foreign_key_constraint(:rider_id)
    |> foreign_key_constraint(:vehicle_category_id)
    |> check_constraint(:pickup_lat, name: :ride_quotes_pickup_lat_range)
    |> check_constraint(:dropoff_lat, name: :ride_quotes_dropoff_lat_range)
    |> check_constraint(:pickup_lng, name: :ride_quotes_pickup_lng_range)
    |> check_constraint(:dropoff_lng, name: :ride_quotes_dropoff_lng_range)
    |> check_constraint(:distance_m, name: :ride_quotes_distance_non_negative)
    |> check_constraint(:duration_s, name: :ride_quotes_duration_non_negative)
    |> check_constraint(:final_fare_kes, name: :ride_quotes_money_non_negative)
    |> check_constraint(:base_fare_kes, name: :ride_quotes_base_fare_non_negative)
    |> check_constraint(:discount_percent, name: :ride_quotes_discount_percent_range)
    |> check_constraint(:discount_amount_kes, name: :ride_quotes_discount_amount_non_negative)
    |> check_constraint(:surge_multiplier, name: :ride_quotes_surge_range)
    |> check_constraint(:currency, name: :ride_quotes_currency_kes)
  end
end
