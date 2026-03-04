defmodule Liddr.Rides.Ride do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(requested offering accepted driver_arriving arrived in_progress cancelled completed)
  @product_types ~w(solo shared)

  schema "rides" do
    field :status, :string
    field :product_type, :string, default: "solo"
    field :pickup_lat, :decimal
    field :pickup_lng, :decimal
    field :dropoff_lat, :decimal
    field :dropoff_lng, :decimal
    field :requested_at, :utc_datetime_usec
    field :accepted_at, :utc_datetime_usec
    field :driver_arriving_at, :utc_datetime_usec
    field :arrived_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :arrival_distance_m, :integer
    field :completion_distance_m, :integer
    field :cancelled_at, :utc_datetime_usec
    field :cancellation_reason_code, :string
    field :cancelled_by_user_id, :id
    field :no_show_marked_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :payment_mode, :string
    field :final_fare_kes, :decimal
    field :final_pricing_payload, :map, default: %{}
    field :notes, :string
    field :metadata, :map, default: %{}
    field :rider_id, :id
    field :driver_id, :id
    field :quote_id, :id
    field :vehicle_category_id, :id

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(ride, attrs) do
    ride
    |> cast(attrs, [
      :rider_id,
      :driver_id,
      :quote_id,
      :vehicle_category_id,
      :status,
      :product_type,
      :pickup_lat,
      :pickup_lng,
      :dropoff_lat,
      :dropoff_lng,
      :requested_at,
      :accepted_at,
      :driver_arriving_at,
      :arrived_at,
      :started_at,
      :arrival_distance_m,
      :completion_distance_m,
      :cancelled_at,
      :cancellation_reason_code,
      :cancelled_by_user_id,
      :no_show_marked_at,
      :completed_at,
      :payment_mode,
      :final_fare_kes,
      :final_pricing_payload,
      :notes,
      :metadata
    ])
    |> validate_required([
      :rider_id,
      :vehicle_category_id,
      :status,
      :pickup_lat,
      :pickup_lng,
      :dropoff_lat,
      :dropoff_lng,
      :requested_at
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:product_type, @product_types)
    |> foreign_key_constraint(:rider_id)
    |> foreign_key_constraint(:driver_id)
    |> foreign_key_constraint(:cancelled_by_user_id)
    |> foreign_key_constraint(:quote_id)
    |> foreign_key_constraint(:vehicle_category_id)
    |> unique_constraint(:driver_id, name: :rides_unique_active_driver_idx)
    |> check_constraint(:status, name: :rides_status_valid)
    |> check_constraint(:product_type, name: :rides_product_type_valid)
    |> check_constraint(:pickup_lat, name: :rides_pickup_lat_range)
    |> check_constraint(:dropoff_lat, name: :rides_dropoff_lat_range)
    |> check_constraint(:pickup_lng, name: :rides_pickup_lng_range)
    |> check_constraint(:dropoff_lng, name: :rides_dropoff_lng_range)
    |> check_constraint(:driver_id, name: :rides_accepted_driver_presence)
    |> check_constraint(:payment_mode, name: :rides_payment_mode_valid)
    |> check_constraint(:final_fare_kes, name: :rides_completion_money_non_negative)
    |> check_constraint(:arrival_distance_m, name: :rides_arrival_distance_non_negative)
    |> check_constraint(:completion_distance_m, name: :rides_completion_distance_non_negative)
  end
end
