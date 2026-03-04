defmodule Liddr.Rides.Requests.Lookup do
  @moduledoc false

  import Ecto.Query

  alias Liddr.Repo
  alias Liddr.Rides.ProductType
  alias Liddr.Rides.Requests.Params, as: RequestParams
  alias Liddr.Rides.RideQuote
  alias Liddr.Rides.VehicleCategory
  alias Liddr.Subscriptions.PaymentUtils

  def fetch_vehicle_category!(attrs) do
    category_id =
      attrs
      |> PaymentUtils.get_value(:vehicle_category_id)
      |> RequestParams.parse_positive_integer()

    if is_nil(category_id), do: Repo.rollback(:invalid_vehicle_category_id)

    Repo.one(
      from vc in VehicleCategory,
        where: vc.id == ^category_id and vc.is_active == true,
        limit: 1
    ) || Repo.rollback(:vehicle_category_not_found)
  end

  def fetch_valid_quote!(attrs, rider_user_id, category_id, product_type, now) do
    quote_id = PaymentUtils.get_value(attrs, :quote_id)

    if is_nil(quote_id) do
      nil
    else
      parsed_quote_id =
        RequestParams.parse_positive_integer(quote_id) || Repo.rollback(:invalid_quote_id)

      quote =
        Repo.one(
          from q in RideQuote,
            where: q.id == ^parsed_quote_id and q.rider_id == ^rider_user_id,
            limit: 1
        ) || Repo.rollback(:ride_quote_not_found)

      if DateTime.compare(quote.expires_at, now) != :gt do
        Repo.rollback(:ride_quote_expired)
      end

      if quote.vehicle_category_id != category_id do
        Repo.rollback(:ride_quote_vehicle_category_mismatch)
      end

      quote_product_type = ProductType.from_quote_payload(quote.provider_payload)

      if quote_product_type != product_type do
        Repo.rollback(:ride_quote_product_type_mismatch)
      end

      quote
    end
  end

  def fetch_pickup_point(nil, attrs) do
    %{
      lat: PaymentUtils.get_value(attrs, :pickup_lat) |> RequestParams.to_float_or_nil(),
      lng: PaymentUtils.get_value(attrs, :pickup_lng) |> RequestParams.to_float_or_nil()
    }
  end

  def fetch_pickup_point(%RideQuote{} = quote, _attrs) do
    %{
      lat: RequestParams.to_float_or_nil(quote.pickup_lat),
      lng: RequestParams.to_float_or_nil(quote.pickup_lng)
    }
  end

  def fetch_dropoff_coordinates(nil, attrs) do
    %{
      lat: PaymentUtils.get_value(attrs, :dropoff_lat),
      lng: PaymentUtils.get_value(attrs, :dropoff_lng)
    }
  end

  def fetch_dropoff_coordinates(%RideQuote{} = quote, _attrs),
    do: %{lat: quote.dropoff_lat, lng: quote.dropoff_lng}
end
