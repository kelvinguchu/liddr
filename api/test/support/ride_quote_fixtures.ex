defmodule LiddrWeb.RideQuoteFixtures do
  @moduledoc false

  import Ecto.Query
  import Phoenix.ConnTest
  import Plug.Conn, only: [get_req_header: 2]

  alias Decimal, as: D
  alias Liddr.Auth.AuthSession
  alias Liddr.Auth.Crypto
  alias Liddr.Repo
  alias Liddr.Rides.RideQuote
  alias Liddr.Rides.VehicleCategory

  @endpoint LiddrWeb.Endpoint
  @default_final_fare "250.00"

  def post_ride_request(conn, params) do
    post(conn, "/api/rides/requests", with_quote(conn, params, params["vehicle_category_id"]))
  end

  def post_send_request(conn, params) do
    post(conn, "/api/send/requests", with_quote(conn, params, send_category_id()))
  end

  defp with_quote(conn, params, category_id) do
    with nil <- params["quote_id"],
         rider_id when is_integer(rider_id) <- rider_id(conn),
         true <- is_integer(category_id) and Repo.exists?(category_query(category_id)),
         {:ok, points} <- route_points(params) do
      Map.put(params, "quote_id", quote_id!(rider_id, category_id, points, params))
    else
      _ -> params
    end
  end

  defp rider_id(conn) do
    with ["Bearer " <> token | _] <- get_req_header(conn, "authorization"),
         %AuthSession{user_id: user_id} <-
           Repo.get_by(AuthSession, session_token_hash: Crypto.token_hash(token)) do
      user_id
    else
      _ -> nil
    end
  end

  defp category_query(category_id), do: from(c in VehicleCategory, where: c.id == ^category_id)

  defp send_category_id do
    Repo.one(from c in VehicleCategory, where: c.slug == "send", select: c.id, limit: 1)
  end

  defp route_points(params) do
    with {:ok, pickup_lat} <- coordinate(params, "pickup_lat", -90, 90),
         {:ok, pickup_lng} <- coordinate(params, "pickup_lng", -180, 180),
         {:ok, dropoff_lat} <- coordinate(params, "dropoff_lat", -90, 90),
         {:ok, dropoff_lng} <- coordinate(params, "dropoff_lng", -180, 180) do
      {:ok, {pickup_lat, pickup_lng, dropoff_lat, dropoff_lng}}
    end
  end

  defp coordinate(params, key, min, max) do
    with value when not is_nil(value) <- params[key],
         {decimal, ""} <- value |> to_string() |> D.parse(),
         true <- D.compare(decimal, min) != :lt and D.compare(decimal, max) != :gt do
      {:ok, D.round(decimal, 7)}
    else
      _ -> :error
    end
  end

  defp quote_id!(
         rider_id,
         category_id,
         {pickup_lat, pickup_lng, dropoff_lat, dropoff_lng},
         params
       ) do
    product_type = params["product_type"] || "solo"

    existing_id =
      Repo.one(
        from q in RideQuote,
          where:
            q.rider_id == ^rider_id and q.vehicle_category_id == ^category_id and
              q.pickup_lat == ^pickup_lat and q.pickup_lng == ^pickup_lng and
              q.dropoff_lat == ^dropoff_lat and q.dropoff_lng == ^dropoff_lng and
              fragment("? ->> 'product_type' = ?", q.provider_payload, ^product_type),
          select: q.id,
          limit: 1
      )

    existing_id ||
      insert_quote!(
        rider_id,
        category_id,
        {pickup_lat, pickup_lng, dropoff_lat, dropoff_lng},
        product_type
      )
  end

  defp insert_quote!(rider_id, category_id, points, product_type) do
    {pickup_lat, pickup_lng, dropoff_lat, dropoff_lng} = points
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    zero = D.new("0.00")
    fare = D.new(@default_final_fare)

    %RideQuote{}
    |> RideQuote.create_changeset(%{
      "rider_id" => rider_id,
      "vehicle_category_id" => category_id,
      "pickup_lat" => pickup_lat,
      "pickup_lng" => pickup_lng,
      "dropoff_lat" => dropoff_lat,
      "dropoff_lng" => dropoff_lng,
      "distance_m" => 2340,
      "duration_s" => 620,
      "base_amount_kes" => zero,
      "distance_amount_kes" => zero,
      "time_amount_kes" => zero,
      "min_fare_kes" => zero,
      "surge_multiplier" => D.new("1.00"),
      "subtotal_kes" => fare,
      "base_fare_kes" => fare,
      "discount_percent" => zero,
      "discount_amount_kes" => zero,
      "final_fare_kes" => fare,
      "currency" => "KES",
      "provider" => "google_routes",
      "provider_payload" => %{"product_type" => product_type},
      "expires_at" => DateTime.add(now, 3_600, :second)
    })
    |> Repo.insert!()
    |> Map.fetch!(:id)
  end
end
