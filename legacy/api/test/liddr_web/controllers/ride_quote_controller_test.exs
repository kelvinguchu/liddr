defmodule LiddrWeb.RideQuoteControllerTest do
  use LiddrWeb.ConnCase, async: false

  alias Decimal, as: D
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

  defmodule FakeRoutesClient do
    @behaviour Liddr.Maps.RoutesClientBehaviour

    @impl true
    def compute_route(input) do
      send(self(), {:routes_input, input})

      {:ok,
       %{
         distance_m: 2_340,
         duration_s: 620,
         static_duration_s: 560,
         polyline: "encoded_polyline",
         raw: %{"routes" => [%{}]}
       }}
    end
  end

  defmodule FakeMarketMultiplier do
    alias Decimal, as: D

    def build(_category, _pickup, _now) do
      {:ok,
       %{
         time_multiplier: D.new("1.20"),
         demand_multiplier: D.new("1.10"),
         market_multiplier: D.new("1.32"),
         demand_ratio: D.new("1.40"),
         available_driver_count: 5,
         active_request_count: 7
       }}
    end
  end

  defmodule FakeRoutesClientFailure do
    @behaviour Liddr.Maps.RoutesClientBehaviour

    @impl true
    def compute_route(_input) do
      {:error, {:google_maps_transport_error, :compute_routes, "timeout"}}
    end
  end

  setup do
    previous_client = Application.get_env(:liddr, :google_routes_client)
    previous_multiplier = Application.get_env(:liddr, :ride_market_multiplier)
    Application.put_env(:liddr, :google_routes_client, FakeRoutesClient)
    Application.put_env(:liddr, :ride_market_multiplier, FakeMarketMultiplier)

    on_exit(fn ->
      if previous_client do
        Application.put_env(:liddr, :google_routes_client, previous_client)
      else
        Application.delete_env(:liddr, :google_routes_client)
      end

      if previous_multiplier do
        Application.put_env(:liddr, :ride_market_multiplier, previous_multiplier)
      else
        Application.delete_env(:liddr, :ride_market_multiplier)
      end
    end)

    :ok
  end

  test "POST /api/rides/quote requires rider role", %{conn: conn} do
    %{auth_conn: auth_conn} = AuthFixtures.authenticate_driver!(conn)

    conn =
      post(auth_conn, "/api/rides/quote", %{
        "vehicle_category_id" => 1,
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000"
      })

    assert %{"error" => %{"code" => "FORBIDDEN_ROLE"}} = json_response(conn, 403)
  end

  test "POST /api/rides/quote returns route + fare breakdown using vehicle pricing", %{conn: conn} do
    %{auth_conn: auth_conn} = AuthFixtures.authenticate_rider!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!(%{slug: "motorbike"})

    conn =
      post(auth_conn, "/api/rides/quote", %{
        "vehicle_category_id" => category_id,
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000"
      })

    response = json_response(conn, 201)

    assert %{
             "data" => %{
               "quote" => %{
                 "vehicle_category_id" => ^category_id,
                 "route" => %{"distance_m" => 2340, "duration_s" => 620},
                 "pricing" => %{
                   "currency" => "KES",
                   "surge_multiplier" => surge,
                   "time_multiplier" => "1.20",
                   "demand_multiplier" => "1.10",
                   "market_multiplier" => "1.32",
                   "final_fare_kes" => final_fare
                 }
               }
             }
           } = response

    assert D.compare(D.new(surge), D.new("1.32")) == :eq
    assert D.compare(D.new(final_fare), D.new("0")) == :gt
    assert_received {:routes_input, %{travel_mode: "TWO_WHEELER"}}
    refute get_in(response, ["data", "quote", "pricing", "booking_fee_kes"])
  end

  test "POST /api/rides/quote with shared product_type applies dynamic discount and rounds fare",
       %{conn: conn} do
    %{auth_conn: auth_conn} = AuthFixtures.authenticate_rider!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!(%{slug: "basic"})

    solo_conn =
      post(auth_conn, "/api/rides/quote", %{
        "vehicle_category_id" => category_id,
        "product_type" => "solo",
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000"
      })

    shared_conn =
      post(auth_conn, "/api/rides/quote", %{
        "vehicle_category_id" => category_id,
        "product_type" => "shared",
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "shared_extra_eta_min" => 2.0,
        "shared_extra_detour_km" => 0.8
      })

    assert %{"data" => %{"quote" => %{"pricing" => %{"final_fare_kes" => solo_final}}}} =
             json_response(solo_conn, 201)

    assert %{
             "data" => %{
               "quote" => %{
                 "product_type" => "shared",
                 "pricing" => %{
                   "final_fare_kes" => shared_final,
                   "shared_pricing" => %{
                     "enabled" => true,
                     "solo_fare_kes" => _,
                     "shared_fare_kes" => _,
                     "discount_percent" => discount_percent
                   }
                 }
               }
             }
           } = json_response(shared_conn, 201)

    assert D.compare(D.new(shared_final), D.new(solo_final)) in [:lt, :eq]
    assert D.compare(D.new(discount_percent), D.new("5.00")) in [:gt, :eq]

    {shared_int, ""} = Integer.parse(String.replace(shared_final, ".00", ""))
    assert rem(shared_int, 10) == 0
  end

  test "POST /api/rides/quote blocks shared product_type for two-wheel categories", %{conn: conn} do
    %{auth_conn: auth_conn} = AuthFixtures.authenticate_rider!(conn)
    motorbike_id = VerificationFixtures.insert_vehicle_category!(%{slug: "motorbike"})
    e_motorbike_id = VerificationFixtures.insert_vehicle_category!(%{slug: "electric_motorbike"})

    motorbike_conn =
      post(auth_conn, "/api/rides/quote", %{
        "vehicle_category_id" => motorbike_id,
        "product_type" => "shared",
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000"
      })

    assert %{"error" => %{"code" => "SHARED_NOT_SUPPORTED_FOR_CATEGORY"}} =
             json_response(motorbike_conn, 422)

    e_motorbike_conn =
      post(auth_conn, "/api/rides/quote", %{
        "vehicle_category_id" => e_motorbike_id,
        "product_type" => "shared",
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000"
      })

    assert %{"error" => %{"code" => "SHARED_NOT_SUPPORTED_FOR_CATEGORY"}} =
             json_response(e_motorbike_conn, 422)
  end

  test "POST /api/rides/quote surfaces upstream transport errors", %{conn: conn} do
    previous_client = Application.get_env(:liddr, :google_routes_client)
    Application.put_env(:liddr, :google_routes_client, FakeRoutesClientFailure)

    on_exit(fn ->
      if previous_client do
        Application.put_env(:liddr, :google_routes_client, previous_client)
      else
        Application.delete_env(:liddr, :google_routes_client)
      end
    end)

    %{auth_conn: auth_conn} = AuthFixtures.authenticate_rider!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()

    conn =
      post(auth_conn, "/api/rides/quote", %{
        "vehicle_category_id" => category_id,
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000"
      })

    assert %{"error" => %{"code" => "GOOGLE_MAPS_UPSTREAM_TRANSPORT_ERROR"}} =
             json_response(conn, 503)
  end
end
