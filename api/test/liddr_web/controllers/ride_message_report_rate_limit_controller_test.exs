defmodule LiddrWeb.RideMessageReportRateLimitControllerTest do
  use LiddrWeb.ConnCase, async: false

  alias Liddr.Accounts.User
  alias Liddr.Moderation.ReportCategory
  alias Liddr.Repo
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

  test "ride message report endpoint enforces per-user report rate limit", %{conn: conn} do
    limiter_key = Liddr.Moderation.ActionRateLimiter
    previous_limiter = Application.get_env(:liddr, limiter_key, [])

    Application.put_env(
      :liddr,
      limiter_key,
      Keyword.merge(previous_limiter,
        ride_message_report_window_seconds: 3_600,
        ride_message_report_max_requests: 2
      )
    )

    on_exit(fn -> Application.put_env(:liddr, limiter_key, previous_limiter) end)

    %{rider_conn: rider_conn, driver_conn: driver_conn, ride_id: ride_id} =
      setup_assigned_ride!(conn)

    category =
      insert_report_category!("ride_message_abuse_rl_#{System.unique_integer([:positive])}")

    for seq <- 1..2 do
      assert %{"data" => %{"message" => %{"id" => message_id}}} =
               post(driver_conn, "/api/rides/#{ride_id}/messages", %{
                 "body" => "Reportable content #{seq}"
               })
               |> json_response(201)

      assert %{"data" => %{"report" => _report}} =
               post(rider_conn, "/api/rides/#{ride_id}/messages/#{message_id}/report", %{
                 "category_slug" => category.slug,
                 "description" => "Abusive message #{seq}"
               })
               |> json_response(201)
    end

    assert %{"data" => %{"message" => %{"id" => blocked_message_id}}} =
             post(driver_conn, "/api/rides/#{ride_id}/messages", %{
               "body" => "This report should be blocked by limiter"
             })
             |> json_response(201)

    assert %{"error" => %{"code" => "RIDE_MESSAGE_REPORT_RATE_LIMITED"}} =
             post(rider_conn, "/api/rides/#{ride_id}/messages/#{blocked_message_id}/report", %{
               "category_slug" => category.slug,
               "description" => "Expected to hit report limiter"
             })
             |> json_response(429)
  end

  defp setup_assigned_ride!(conn) do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    _ = create_eligible_driver_profile!(driver_id, category_id)

    %{"data" => %{"ride" => %{"id" => ride_id}, "offers" => [%{"id" => offer_id}]}} =
      rider_conn
      |> post("/api/rides/requests", %{
        "vehicle_category_id" => category_id,
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "offer_limit" => 1
      })
      |> json_response(201)

    _ = post(driver_conn, "/api/rides/offers/#{offer_id}/accept", %{}) |> json_response(200)
    %{rider_conn: rider_conn, driver_conn: driver_conn, ride_id: ride_id}
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
      display_order: 301
    })
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
