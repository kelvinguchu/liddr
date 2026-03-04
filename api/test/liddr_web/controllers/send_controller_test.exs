defmodule LiddrWeb.SendControllerTest do
  use LiddrWeb.ConnCase, async: false

  alias Decimal, as: D
  alias Liddr.Repo
  alias Liddr.Accounts.User
  alias Liddr.Rides.Ride
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

  defmodule FakeRoutesClient do
    @behaviour Liddr.Maps.RoutesClientBehaviour

    @impl true
    def compute_route(input) do
      send(self(), {:send_routes_input, input})

      {:ok,
       %{
         distance_m: 2_120,
         duration_s: 520,
         static_duration_s: 480,
         polyline: "send_polyline",
         raw: %{"routes" => [%{}]}
       }}
    end
  end

  defmodule FakeMarketMultiplier do
    alias Decimal, as: D

    def build(_category, _pickup, _now) do
      {:ok,
       %{
         time_multiplier: D.new("1.00"),
         demand_multiplier: D.new("1.00"),
         market_multiplier: D.new("1.00"),
         demand_ratio: D.new("1.00"),
         available_driver_count: 10,
         active_request_count: 5
       }}
    end
  end

  setup do
    previous_client = Application.get_env(:liddr, :google_routes_client)
    previous_multiplier = Application.get_env(:liddr, :ride_market_multiplier)
    Application.put_env(:liddr, :google_routes_client, FakeRoutesClient)
    Application.put_env(:liddr, :ride_market_multiplier, FakeMarketMultiplier)

    on_exit(fn ->
      restore_env(:google_routes_client, previous_client)
      restore_env(:ride_market_multiplier, previous_multiplier)
    end)

    :ok
  end

  test "POST /api/send/quote requires rider role", %{conn: conn} do
    %{auth_conn: auth_conn} = AuthFixtures.authenticate_driver!(conn)

    conn =
      post(auth_conn, "/api/send/quote", %{
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000"
      })

    assert %{"error" => %{"code" => "FORBIDDEN_ROLE"}} = json_response(conn, 403)
  end

  test "POST /api/send/quote always uses active send category", %{conn: conn} do
    %{auth_conn: auth_conn} = AuthFixtures.authenticate_rider!(conn)
    send_category_id = VerificationFixtures.insert_vehicle_category!(%{slug: "send"})
    basic_category_id = VerificationFixtures.insert_vehicle_category!(%{slug: "basic"})

    conn =
      post(auth_conn, "/api/send/quote", %{
        "vehicle_category_id" => basic_category_id,
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000"
      })

    assert %{"data" => %{"quote" => %{"vehicle_category_id" => ^send_category_id}}} =
             json_response(conn, 201)

    assert_received {:send_routes_input, _input}
  end

  test "POST /api/send/requests creates a send ride with delivery details", %{conn: conn} do
    %{auth_conn: auth_conn, user_id: rider_user_id} = AuthFixtures.authenticate_rider!(conn)
    %{user_id: recipient_user_id} = AuthFixtures.authenticate_rider!(conn)
    recipient_phone = Repo.get!(User, recipient_user_id).phone
    send_category_id = VerificationFixtures.insert_vehicle_category!(%{slug: "send"})

    conn =
      post(auth_conn, "/api/send/requests", %{
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "sender_name" => "Alice",
        "recipient_name" => "Bob",
        "recipient_phone" => recipient_phone,
        "item_description" => "Small package",
        "item_size" => "small",
        "payer" => "sender",
        "payment_timing" => "after",
        "item_value_kes" => "1500.00",
        "special_instructions" => "Call on arrival"
      })

    assert %{
             "data" => %{
               "ride" => %{"id" => ride_id, "vehicle_category_id" => ^send_category_id},
               "delivery" => %{
                 "sender_name" => "Alice",
                 "recipient_name" => "Bob",
                 "recipient_phone" => recipient_phone,
                 "item_description" => "Small package",
                 "item_size" => "small",
                 "payer" => "sender",
                 "payment_timing" => "after",
                 "item_value_kes" => "1500.00"
               }
             }
           } = json_response(conn, 201)

    ride = Repo.get!(Ride, ride_id)
    assert ride.rider_id == rider_user_id
    assert ride.product_type == "solo"
    assert get_in(ride.metadata, ["delivery", "recipient_phone"]) == recipient_phone
  end

  test "POST /api/send/requests requires recipient to have app account", %{conn: conn} do
    %{auth_conn: auth_conn} = AuthFixtures.authenticate_rider!(conn)
    _send_category_id = VerificationFixtures.insert_vehicle_category!(%{slug: "send"})

    conn =
      post(auth_conn, "/api/send/requests", %{
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "sender_name" => "Alice",
        "recipient_name" => "Bob",
        "recipient_phone" => "0712345678",
        "item_description" => "Small package",
        "item_size" => "small",
        "payer" => "sender",
        "payment_timing" => "after"
      })

    assert %{"error" => %{"code" => "RECIPIENT_APP_ACCOUNT_REQUIRED"}} = json_response(conn, 422)
  end

  test "POST /api/send/requests validates required delivery fields", %{conn: conn} do
    %{auth_conn: auth_conn} = AuthFixtures.authenticate_rider!(conn)
    _send_category_id = VerificationFixtures.insert_vehicle_category!(%{slug: "send"})

    conn =
      post(auth_conn, "/api/send/requests", %{
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "sender_name" => "Alice",
        "item_size" => "small",
        "payer" => "sender",
        "payment_timing" => "after",
        "recipient_name" => "Bob",
        "item_description" => "Small package"
      })

    assert %{"error" => %{"code" => "MISSING_RECIPIENT_PHONE"}} = json_response(conn, 422)
  end

  test "GET /api/send/history/sender returns only send rides for rider", %{conn: conn} do
    %{auth_conn: auth_conn, user_id: rider_user_id} = AuthFixtures.authenticate_rider!(conn)
    send_category_id = VerificationFixtures.insert_vehicle_category!(%{slug: "send"})
    basic_category_id = VerificationFixtures.insert_vehicle_category!(%{slug: "basic"})

    send_ride = insert_ride!(rider_user_id, nil, send_category_id)
    _basic_ride = insert_ride!(rider_user_id, nil, basic_category_id)

    conn = get(auth_conn, "/api/send/history/sender")

    assert %{"data" => %{"rides" => rides}} = json_response(conn, 200)
    assert Enum.any?(rides, &(&1["id"] == send_ride.id))
    assert Enum.all?(rides, &(&1["vehicle_category_id"] == send_category_id))
  end

  test "GET /api/send/history/courier returns only send rides for driver", %{conn: conn} do
    %{auth_conn: auth_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    send_category_id = VerificationFixtures.insert_vehicle_category!(%{slug: "send"})
    basic_category_id = VerificationFixtures.insert_vehicle_category!(%{slug: "basic"})

    driver_user = Repo.get!(User, driver_user_id)

    _driver_profile =
      VerificationFixtures.create_driver!(
        user: driver_user,
        vehicle_category_id: send_category_id,
        account_status: "active",
        verification_status: "approved",
        subscription_status: "active",
        is_available: true
      )

    send_ride = insert_ride!(nil, driver_user_id, send_category_id)
    _basic_ride = insert_ride!(nil, driver_user_id, basic_category_id)

    conn = get(auth_conn, "/api/send/history/courier")

    assert %{"data" => %{"rides" => rides}} = json_response(conn, 200)
    assert Enum.any?(rides, &(&1["id"] == send_ride.id))
    assert Enum.all?(rides, &(&1["vehicle_category_id"] == send_category_id))
  end

  defp insert_ride!(rider_id, driver_id, category_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    rider_id = rider_id || Repo.insert!(%User{phone: VerificationFixtures.unique_phone()}).id

    Repo.insert!(%Ride{
      rider_id: rider_id,
      driver_id: driver_id,
      vehicle_category_id: category_id,
      status: "completed",
      pickup_lat: D.new("-1.2921000"),
      pickup_lng: D.new("36.8219000"),
      dropoff_lat: D.new("-1.3000000"),
      dropoff_lng: D.new("36.8000000"),
      requested_at: DateTime.add(now, -3_600, :second),
      completed_at: DateTime.add(now, -1_800, :second),
      metadata: %{}
    })
  end

  defp restore_env(key, nil), do: Application.delete_env(:liddr, key)
  defp restore_env(key, value), do: Application.put_env(:liddr, key, value)
end
