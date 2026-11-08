defmodule LiddrWeb.RideMessageModerationControllerTest do
  use LiddrWeb.ConnCase, async: false
  import Ecto.Query

  alias Liddr.Accounts.User
  alias Liddr.Moderation.Report
  alias Liddr.Moderation.ReportCategory
  alias Liddr.Moderation.UserEnforcement
  alias Liddr.Repo
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

  test "quick actions endpoint supports locale-aware labels", %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)

    assert %{"data" => %{"quick_actions" => quick_actions}} =
             get(rider_conn, "/api/rides/messages/quick-actions?locale=sw-KE")
             |> json_response(200)

    assert is_list(quick_actions)
    assert length(quick_actions) > 0

    on_my_way = Enum.find(quick_actions, &(&1["code"] == "on_my_way"))

    assert on_my_way["label_default"] == "I am on my way"
    assert on_my_way["label_localized"] == "Niko njiani"
    assert on_my_way["locale"] == "sw"
  end

  test "hidden message is hidden only for requesting user", %{conn: conn} do
    %{rider_conn: rider_conn, driver_conn: driver_conn, ride_id: ride_id} =
      setup_assigned_ride!(conn)

    assert %{"data" => %{"message" => %{"id" => message_id}}} =
             post(driver_conn, "/api/rides/#{ride_id}/messages", %{
               "body" => "I am at your pickup pin"
             })
             |> json_response(201)

    assert %{"data" => %{"message" => %{"id" => ^message_id}}} =
             post(rider_conn, "/api/rides/#{ride_id}/messages/#{message_id}/hide", %{})
             |> json_response(200)

    assert %{"data" => %{"messages" => rider_messages}} =
             get(rider_conn, "/api/rides/#{ride_id}/messages")
             |> json_response(200)

    refute Enum.any?(rider_messages, &(&1["id"] == message_id))

    assert %{"data" => %{"messages" => driver_messages}} =
             get(driver_conn, "/api/rides/#{ride_id}/messages")
             |> json_response(200)

    assert Enum.any?(driver_messages, &(&1["id"] == message_id))
  end

  test "reporting a ride message creates moderation report and flags metadata", %{conn: conn} do
    %{
      rider_conn: rider_conn,
      driver_conn: driver_conn,
      ride_id: ride_id,
      rider_id: rider_id,
      driver_id: driver_id
    } =
      setup_assigned_ride!(conn)

    category = insert_report_category!("ride_message_abuse")

    assert %{"data" => %{"message" => %{"id" => message_id}}} =
             post(driver_conn, "/api/rides/#{ride_id}/messages", %{
               "body" => "You should pay me extra off app"
             })
             |> json_response(201)

    assert %{
             "data" => %{
               "message" => %{"id" => ^message_id, "metadata" => %{"moderation" => moderation}},
               "report" => %{"id" => report_id, "context_reference" => context_reference}
             }
           } =
             post(rider_conn, "/api/rides/#{ride_id}/messages/#{message_id}/report", %{
               "category_slug" => category.slug,
               "description" => "Driver is soliciting off-platform payment"
             })
             |> json_response(201)

    assert context_reference == "ride_message:#{message_id}"
    assert moderation["reported"] == true
    assert moderation["report_count"] == 1
    assert moderation["abuse_flagged"] == false

    assert %{
             reporter_user_id: ^rider_id,
             reported_user_id: ^driver_id,
             context_type: "ride",
             context_reference: ^context_reference
           } = Repo.get!(Report, report_id)

    assert %{"data" => %{"messages" => rider_messages}} =
             get(rider_conn, "/api/rides/#{ride_id}/messages")
             |> json_response(200)

    refute Enum.any?(rider_messages, &(&1["id"] == message_id))
  end

  test "repeated ride message reports auto-restrict communication and block sends", %{conn: conn} do
    policy_key = Liddr.Rides.MessageModerationPolicy
    previous_policy = Application.get_env(:liddr, policy_key, [])

    Application.put_env(
      :liddr,
      policy_key,
      Keyword.merge(previous_policy,
        report_window_days: 7,
        auto_restrict_threshold: 2,
        signal_cooldown_days: 1
      )
    )

    on_exit(fn -> Application.put_env(:liddr, policy_key, previous_policy) end)

    %{auth_conn: driver_conn, user_id: driver_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    _ = create_eligible_driver_profile!(driver_id, category_id)
    category = insert_report_category!("harassment_or_abuse")

    _ = report_one_driver_message!(conn, driver_conn, category_id, category.slug)
    _ = report_one_driver_message!(conn, driver_conn, category_id, category.slug)

    assert %UserEnforcement{
             user_id: ^driver_id,
             scope: "communication",
             action: "feature_restriction",
             status: "active"
           } =
             Repo.one(
               from ue in UserEnforcement,
                 where:
                   ue.user_id == ^driver_id and ue.scope == "communication" and
                     ue.action == "feature_restriction" and ue.status == "active",
                 order_by: [desc: ue.id],
                 limit: 1
             )

    assert Repo.exists?(
             from r in Report,
               where:
                 r.reported_user_id == ^driver_id and r.source == "system" and
                   r.context_type == "profile" and
                   r.context_reference == ^"message_abuse_signal:#{driver_id}"
           )

    %{rider_conn: rider_conn, ride_id: ride_id} =
      create_assigned_ride_for_driver!(conn, driver_conn, category_id)

    assert %{"error" => %{"code" => "RIDE_MESSAGE_COMMUNICATION_RESTRICTED"}} =
             post(driver_conn, "/api/rides/#{ride_id}/messages", %{
               "body" => "I can still message?"
             })
             |> json_response(403)

    assert %{"data" => %{"messages" => []}} =
             get(rider_conn, "/api/rides/#{ride_id}/messages")
             |> json_response(200)

    assert %{"data" => %{"notifications" => driver_notifications}} =
             get(driver_conn, "/api/notifications?limit=20")
             |> json_response(200)

    assert Enum.any?(driver_notifications, fn row ->
             row["event_type"] == "ride_message_communication_restricted"
           end)
  end

  defp setup_assigned_ride!(conn) do
    %{auth_conn: rider_conn, user_id: rider_id} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    _ = create_eligible_driver_profile!(driver_id, category_id)

    %{"data" => %{"ride" => %{"id" => ride_id}, "offers" => [%{"id" => offer_id}]}} =
      rider_conn
      |> post_ride_request(%{
        "vehicle_category_id" => category_id,
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "offer_limit" => 1
      })
      |> json_response(201)

    _ = post(driver_conn, "/api/rides/offers/#{offer_id}/accept", %{}) |> json_response(200)

    %{
      rider_conn: rider_conn,
      driver_conn: driver_conn,
      ride_id: ride_id,
      rider_id: rider_id,
      driver_id: driver_id
    }
  end

  defp insert_report_category!(slug) do
    Repo.insert!(%ReportCategory{
      slug: slug,
      label: "Ride Message Abuse",
      description: "Ride message moderation category",
      applies_to: "both",
      severity_level_default: 3,
      recommended_action: "review",
      requires_immediate_attention: false,
      is_active: true,
      display_order: 300
    })
  end

  defp report_one_driver_message!(conn, driver_conn, category_id, category_slug) do
    %{rider_conn: rider_conn, ride_id: ride_id} =
      create_assigned_ride_for_driver!(conn, driver_conn, category_id)

    %{"data" => %{"message" => %{"id" => message_id}}} =
      post(driver_conn, "/api/rides/#{ride_id}/messages", %{
        "body" => "Contact me off app for this ride"
      })
      |> json_response(201)

    _ =
      post(rider_conn, "/api/rides/#{ride_id}/messages/#{message_id}/report", %{
        "category_slug" => category_slug,
        "description" => "Unsafe off-app solicitation"
      })
      |> json_response(201)

    _ =
      post(rider_conn, "/api/rides/#{ride_id}/cancel", %{
        "reason" => "rider_changed_mind"
      })
      |> json_response(200)

    :ok
  end

  defp create_assigned_ride_for_driver!(conn, driver_conn, category_id) do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)

    %{"data" => %{"ride" => %{"id" => ride_id}, "offers" => [%{"id" => offer_id}]}} =
      rider_conn
      |> post_ride_request(%{
        "vehicle_category_id" => category_id,
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "offer_limit" => 1
      })
      |> json_response(201)

    _ = post(driver_conn, "/api/rides/offers/#{offer_id}/accept", %{}) |> json_response(200)

    %{rider_conn: rider_conn, ride_id: ride_id}
  end

  defp create_eligible_driver_profile!(user_id, category_id) do
    user = Repo.get!(User, user_id)

    driver =
      VerificationFixtures.create_driver!(
        user: user,
        vehicle_category_id: category_id,
        account_status: "active",
        verification_status: "approved",
        subscription_status: "active",
        is_available: true
      )

    _ =
      VerificationFixtures.create_driver_location!(driver.user_id,
        lat: Decimal.new("-1.2921000"),
        lng: Decimal.new("36.8219000")
      )

    driver
  end
end
