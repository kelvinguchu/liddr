defmodule LiddrWeb.SendProhibitedItemsControllerTest do
  use LiddrWeb.ConnCase, async: false

  alias Liddr.Accounts.User
  alias Liddr.Repo
  alias Liddr.Rides.ProhibitedItem
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

  defmodule FakeRoutesClient do
    @behaviour Liddr.Maps.RoutesClientBehaviour

    @impl true
    def compute_route(_input) do
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

  test "POST /api/send/requests blocks prohibited items with block severity", %{conn: conn} do
    %{auth_conn: auth_conn} = AuthFixtures.authenticate_rider!(conn)
    %{user_id: recipient_user_id} = AuthFixtures.authenticate_rider!(conn)
    recipient_phone = Repo.get!(User, recipient_user_id).phone
    _send_category_id = VerificationFixtures.insert_vehicle_category!(%{slug: "send"})
    insert_prohibited_item!("firearm", "block", "Firearms are not allowed")

    conn =
      post_send_request(auth_conn, %{
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "sender_name" => "Alice",
        "recipient_name" => "Bob",
        "recipient_phone" => recipient_phone,
        "item_description" => "Need to deliver a firearm holster",
        "item_size" => "small",
        "payer" => "sender",
        "payment_timing" => "after"
      })

    assert %{
             "error" => %{
               "code" => "SEND_PROHIBITED_ITEM_BLOCKED",
               "matches" => [%{"keyword" => "firearm", "severity" => "block"}]
             }
           } = json_response(conn, 422)
  end

  test "POST /api/send/requests requires liability ack for warned items", %{conn: conn} do
    %{auth_conn: auth_conn} = AuthFixtures.authenticate_rider!(conn)
    %{user_id: recipient_user_id} = AuthFixtures.authenticate_rider!(conn)
    recipient_phone = Repo.get!(User, recipient_user_id).phone
    _send_category_id = VerificationFixtures.insert_vehicle_category!(%{slug: "send"})
    insert_prohibited_item!("jewellery", "warn", "High-value item is sender liability")

    conn =
      post_send_request(auth_conn, %{
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "sender_name" => "Alice",
        "recipient_name" => "Bob",
        "recipient_phone" => recipient_phone,
        "item_description" => "Gold jewellery box",
        "item_size" => "small",
        "payer" => "sender",
        "payment_timing" => "after"
      })

    assert %{"error" => %{"code" => "SEND_LIABILITY_ACK_REQUIRED"}} = json_response(conn, 422)
  end

  test "POST /api/send/requests returns warnings when warned item is acknowledged", %{conn: conn} do
    %{auth_conn: auth_conn} = AuthFixtures.authenticate_rider!(conn)
    %{user_id: recipient_user_id} = AuthFixtures.authenticate_rider!(conn)
    recipient_phone = Repo.get!(User, recipient_user_id).phone
    _send_category_id = VerificationFixtures.insert_vehicle_category!(%{slug: "send"})
    insert_prohibited_item!("jewellery", "warn", "High-value item is sender liability")

    conn =
      post_send_request(auth_conn, %{
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "sender_name" => "Alice",
        "recipient_name" => "Bob",
        "recipient_phone" => recipient_phone,
        "item_description" => "Gold jewellery box",
        "item_size" => "small",
        "payer" => "sender",
        "payment_timing" => "after",
        "liability_acknowledged" => true
      })

    assert %{
             "data" => %{
               "delivery" => %{
                 "liability_acknowledged" => true,
                 "prohibited_item_warnings" => [%{"keyword" => "jewellery", "severity" => "warn"}]
               }
             }
           } = json_response(conn, 201)
  end

  defp restore_env(key, nil), do: Application.delete_env(:liddr, key)
  defp restore_env(key, value), do: Application.put_env(:liddr, key, value)

  defp insert_prohibited_item!(keyword, severity, message) do
    Repo.insert!(%ProhibitedItem{
      keyword: keyword,
      severity: severity,
      message: message,
      is_active: true
    })
  end
end
