defmodule LiddrWeb.DisputeControllerTest do
  use LiddrWeb.ConnCase, async: false

  import Ecto.Query

  alias Liddr.Accounts.Driver
  alias Liddr.Accounts.User
  alias Liddr.Disputes.Compensation
  alias Liddr.Moderation.Report
  alias Liddr.Moderation.ReportCategory
  alias Liddr.Repo
  alias Liddr.Rides.Ride
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

  setup do
    previous_security_mode = System.get_env("SECURITY_MODE")
    previous_ops_ip_allowlist = System.get_env("OPS_IP_ALLOWLIST")

    System.put_env("SECURITY_MODE", "observe")
    System.delete_env("OPS_IP_ALLOWLIST")

    on_exit(fn ->
      restore_env("SECURITY_MODE", previous_security_mode)
      restore_env("OPS_IP_ALLOWLIST", previous_ops_ip_allowlist)
    end)

    ensure_dispute_category!("payment_dispute")
    :ok
  end

  test "POST /api/disputes submits ride dispute for participant", %{conn: conn} do
    %{auth_conn: rider_conn, user_id: rider_id} = AuthFixtures.authenticate_rider!(conn)
    %{user_id: driver_id} = AuthFixtures.authenticate_driver!(conn)
    ride = create_ride!(rider_id, driver_id, "accepted")

    conn =
      post(rider_conn, "/api/disputes", %{
        "ride_id" => ride.id,
        "dispute_type" => "fare_dispute",
        "description" => "Charged more than quoted fare."
      })

    assert %{"data" => dispute} = json_response(conn, 201)
    assert dispute["ride_id"] == ride.id
    assert dispute["dispute_type"] == "fare_dispute"
    assert dispute["reporter_user_id"] == rider_id
    assert dispute["reported_user_id"] == driver_id

    report = Repo.get!(Report, dispute["id"])
    assert report.context_type == "ride"
    assert report.context_reference == Integer.to_string(ride.id)
    assert report.metadata["dispute_type"] == "fare_dispute"
  end

  test "POST /api/disputes rejects requester outside ride", %{conn: conn} do
    %{user_id: rider_id} = AuthFixtures.authenticate_rider!(conn)
    %{user_id: driver_id} = AuthFixtures.authenticate_driver!(conn)
    %{auth_conn: outsider_conn} = AuthFixtures.authenticate_rider!(conn)
    ride = create_ride!(rider_id, driver_id, "accepted")

    conn =
      post(outsider_conn, "/api/disputes", %{
        "ride_id" => ride.id,
        "dispute_type" => "fare_dispute",
        "description" => "Not my ride but attempting dispute."
      })

    assert %{"error" => %{"code" => "RIDE_FORBIDDEN"}} = json_response(conn, 403)
  end

  test "POST /api/disputes enforces per-user creation rate limit", %{conn: conn} do
    %{auth_conn: rider_conn, user_id: rider_id} = AuthFixtures.authenticate_rider!(conn)
    %{user_id: driver_id} = AuthFixtures.authenticate_driver!(conn)

    for seq <- 1..6 do
      ride = create_ride!(rider_id, driver_id, "completed")

      response =
        post(rider_conn, "/api/disputes", %{
          "ride_id" => ride.id,
          "dispute_type" => "fare_dispute",
          "description" => "Rate limit probe #{seq}"
        })

      assert %{"data" => _payload} = json_response(response, 201)
    end

    blocked_ride = create_ride!(rider_id, driver_id, "completed")

    blocked_response =
      post(rider_conn, "/api/disputes", %{
        "ride_id" => blocked_ride.id,
        "dispute_type" => "fare_dispute",
        "description" => "Should be rate limited"
      })

    assert %{"error" => %{"code" => "DISPUTE_CREATE_RATE_LIMITED"}} =
             json_response(blocked_response, 429)
  end

  test "GET /api/disputes/me supports opened and received scopes", %{conn: conn} do
    %{auth_conn: driver_conn, user_id: driver_id} = AuthFixtures.authenticate_driver!(conn)
    %{auth_conn: _rider_conn, user_id: rider_id} = AuthFixtures.authenticate_rider!(conn)

    %{auth_conn: other_rider_conn, user_id: other_rider_id} =
      AuthFixtures.authenticate_rider!(conn)

    opened_ride = create_ride!(rider_id, driver_id, "completed")
    received_ride = create_ride!(other_rider_id, driver_id, "accepted")

    _ =
      post(driver_conn, "/api/disputes", %{
        "ride_id" => opened_ride.id,
        "dispute_type" => "fare_dispute",
        "description" => "Rider did not settle agreed amount."
      })
      |> json_response(201)

    _ =
      post(other_rider_conn, "/api/disputes", %{
        "ride_id" => received_ride.id,
        "dispute_type" => "fare_dispute",
        "description" => "Driver claimed wrong amount."
      })
      |> json_response(201)

    assert %{"data" => %{"disputes" => opened}} =
             get(driver_conn, "/api/disputes/me?scope=opened")
             |> json_response(200)

    assert length(opened) == 1
    assert hd(opened)["reporter_user_id"] == driver_id

    assert %{"data" => %{"disputes" => received}} =
             get(driver_conn, "/api/disputes/me?scope=received")
             |> json_response(200)

    assert length(received) == 1
    assert hd(received)["reported_user_id"] == driver_id

    assert %{"data" => %{"disputes" => all}} =
             get(driver_conn, "/api/disputes/me")
             |> json_response(200)

    assert length(all) == 2
  end

  test "GET /api/disputes/me hides reporter details from the reported user", %{conn: conn} do
    %{auth_conn: driver_conn, user_id: driver_id} = AuthFixtures.authenticate_driver!(conn)
    %{auth_conn: rider_conn, user_id: rider_id} = AuthFixtures.authenticate_rider!(conn)
    ride = create_ride!(rider_id, driver_id, "completed")

    _ =
      post(rider_conn, "/api/disputes", %{
        "ride_id" => ride.id,
        "dispute_type" => "fare_dispute",
        "description" => "Reporter statement that the driver should not read."
      })
      |> json_response(201)

    assert %{"data" => %{"disputes" => [received]}} =
             get(driver_conn, "/api/disputes/me?scope=received") |> json_response(200)

    assert received["dispute_type"] == "fare_dispute"
    assert received["reported_user_id"] == driver_id

    for field <- ~w(reporter_user_id description severity_level resolution_summary) do
      refute Map.has_key?(received, field)
    end

    assert %{"data" => %{"disputes" => [opened]}} =
             get(rider_conn, "/api/disputes/me?scope=opened") |> json_response(200)

    assert opened["description"] == "Reporter statement that the driver should not read."
    assert opened["reporter_user_id"] == rider_id
  end

  test "GET /api/disputes/me keeps safety disputes from the reported user", %{conn: conn} do
    ensure_dispute_category!("harassment_or_abuse")
    %{auth_conn: driver_conn, user_id: driver_id} = AuthFixtures.authenticate_driver!(conn)
    %{auth_conn: rider_conn, user_id: rider_id} = AuthFixtures.authenticate_rider!(conn)
    ride = create_ride!(rider_id, driver_id, "completed")

    _ =
      post(rider_conn, "/api/disputes", %{
        "ride_id" => ride.id,
        "dispute_type" => "safety_incident",
        "description" => "Driver harassed me during the trip."
      })
      |> json_response(201)

    for path <- ["/api/disputes/me", "/api/disputes/me?scope=received"] do
      assert %{"data" => %{"disputes" => []}} = get(driver_conn, path) |> json_response(200)
    end

    assert %{"data" => %{"disputes" => [opened]}} =
             get(rider_conn, "/api/disputes/me") |> json_response(200)

    assert opened["dispute_type"] == "safety_incident"
  end

  test "POST /api/ops/disputes/:id/resolve supports partial refund outcome", %{conn: conn} do
    %{auth_conn: rider_conn, user_id: rider_id} = AuthFixtures.authenticate_rider!(conn)
    %{user_id: driver_id} = AuthFixtures.authenticate_driver!(conn)

    ops_conn =
      AuthFixtures.authenticate_ops!("ops-disputes@example.com")
      |> Map.fetch!(:auth_conn)
      |> AuthFixtures.with_step_up!()

    ride = create_ride!(rider_id, driver_id, "accepted")

    %{"data" => dispute} =
      post(rider_conn, "/api/disputes", %{
        "ride_id" => ride.id,
        "dispute_type" => "fare_dispute",
        "description" => "Final charge exceeded estimate."
      })
      |> json_response(201)

    conn =
      post(ops_conn, "/api/ops/disputes/#{dispute["id"]}/resolve", %{
        "resolution_outcome" => "refund_partial",
        "resolution_amount_kes" => "50.00",
        "summary" => "Issued a partial refund after evidence review."
      })

    assert %{"data" => resolution} = json_response(conn, 201)
    assert resolution["resolution_outcome"] == "refund_partial"
    assert resolution["report"]["status"] == "resolved"
    assert resolution["report"]["resolution_outcome"] == "no_action"
    assert resolution["review"]["metadata"]["dispute_resolution"]["amount_kes"] == "50.00"
    assert resolution["compensation"]["compensation_type"] == "refund_partial"
    assert resolution["compensation"]["amount_kes"] == "50.00"
    assert resolution["compensation"]["beneficiary_user_id"] == rider_id
    assert resolution["compensation"]["counterparty_user_id"] == driver_id

    assert 1 ==
             Repo.aggregate(
               from(c in Compensation, where: c.report_id == ^dispute["id"]),
               :count,
               :id
             )
  end

  test "POST /api/ops/disputes/:id/resolve validates partial refund amount", %{conn: conn} do
    %{auth_conn: rider_conn, user_id: rider_id} = AuthFixtures.authenticate_rider!(conn)
    %{user_id: driver_id} = AuthFixtures.authenticate_driver!(conn)

    ops_conn =
      AuthFixtures.authenticate_ops!("ops-disputes-invalid@example.com")
      |> Map.fetch!(:auth_conn)
      |> AuthFixtures.with_step_up!()

    ride = create_ride!(rider_id, driver_id, "accepted")

    %{"data" => dispute} =
      post(rider_conn, "/api/disputes", %{
        "ride_id" => ride.id,
        "dispute_type" => "fare_dispute",
        "description" => "Charge did not match route."
      })
      |> json_response(201)

    conn =
      post(ops_conn, "/api/ops/disputes/#{dispute["id"]}/resolve", %{
        "resolution_outcome" => "refund_partial",
        "resolution_amount_kes" => "-10"
      })

    assert %{"error" => %{"code" => "INVALID_RESOLUTION_AMOUNT"}} = json_response(conn, 422)
  end

  test "POST /api/ops/disputes/:id/resolve enforces ops rate limit", %{conn: conn} do
    limiter_key = Liddr.Moderation.ActionRateLimiter
    previous_limiter = Application.get_env(:liddr, limiter_key, [])

    Application.put_env(
      :liddr,
      limiter_key,
      Keyword.merge(previous_limiter,
        dispute_ops_resolution_window_seconds: 3_600,
        dispute_ops_resolution_max_requests: 2
      )
    )

    on_exit(fn -> Application.put_env(:liddr, limiter_key, previous_limiter) end)

    %{auth_conn: rider_conn, user_id: rider_id} = AuthFixtures.authenticate_rider!(conn)
    %{user_id: driver_id} = AuthFixtures.authenticate_driver!(conn)

    ops_conn =
      AuthFixtures.authenticate_ops!("ops-dispute-rate-limit@example.com")
      |> Map.fetch!(:auth_conn)
      |> AuthFixtures.with_step_up!()

    disputes =
      for seq <- 1..3 do
        ride = create_ride!(rider_id, driver_id, "completed")

        %{"data" => dispute} =
          post(rider_conn, "/api/disputes", %{
            "ride_id" => ride.id,
            "dispute_type" => "fare_dispute",
            "description" => "Ops resolution limiter probe #{seq}"
          })
          |> json_response(201)

        dispute
      end

    for dispute <- Enum.take(disputes, 2) do
      assert %{"data" => %{"resolution_outcome" => "dismissed"}} =
               post(ops_conn, "/api/ops/disputes/#{dispute["id"]}/resolve", %{
                 "resolution_outcome" => "dismissed",
                 "summary" => "No action after review."
               })
               |> json_response(201)
    end

    blocked_dispute = List.last(disputes)

    assert %{"error" => %{"code" => "DISPUTE_RESOLVE_RATE_LIMITED"}} =
             post(ops_conn, "/api/ops/disputes/#{blocked_dispute["id"]}/resolve", %{
               "resolution_outcome" => "dismissed",
               "summary" => "Expected limiter block."
             })
             |> json_response(429)
  end

  test "GET compensation endpoints return only created compensation rows", %{conn: conn} do
    %{auth_conn: rider_conn, user_id: rider_id} = AuthFixtures.authenticate_rider!(conn)
    %{user_id: driver_id} = AuthFixtures.authenticate_driver!(conn)

    ops_conn =
      AuthFixtures.authenticate_ops!("ops-disputes-comp@example.com")
      |> Map.fetch!(:auth_conn)
      |> AuthFixtures.with_step_up!()

    ride = create_ride!(rider_id, driver_id, "accepted")

    %{"data" => dispute} =
      post(rider_conn, "/api/disputes", %{
        "ride_id" => ride.id,
        "dispute_type" => "fare_dispute",
        "description" => "Charged above estimate."
      })
      |> json_response(201)

    _ =
      post(ops_conn, "/api/ops/disputes/#{dispute["id"]}/resolve", %{
        "resolution_outcome" => "refund_partial",
        "resolution_amount_kes" => "80.00",
        "summary" => "Compensation approved."
      })
      |> json_response(201)

    assert %{"data" => %{"compensations" => rider_compensations}} =
             get(rider_conn, "/api/disputes/me/compensations")
             |> json_response(200)

    assert Enum.any?(rider_compensations, fn row ->
             row["report_id"] == dispute["id"] and row["amount_kes"] == "80.00"
           end)

    assert %{"data" => %{"compensations" => ops_compensations}} =
             get(ops_conn, "/api/ops/disputes/compensations?report_id=#{dispute["id"]}")
             |> json_response(200)

    assert length(ops_compensations) == 1
    assert hd(ops_compensations)["beneficiary_user_id"] == rider_id
  end

  defp create_ride!(rider_id, driver_id, status) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    category_id = VerificationFixtures.insert_vehicle_category!()
    ensure_driver_profile!(driver_id, category_id)

    Repo.insert!(%Ride{
      rider_id: rider_id,
      driver_id: driver_id,
      vehicle_category_id: category_id,
      status: status,
      pickup_lat: Decimal.new("-1.2921000"),
      pickup_lng: Decimal.new("36.8219000"),
      dropoff_lat: Decimal.new("-1.3000000"),
      dropoff_lng: Decimal.new("36.8000000"),
      requested_at: DateTime.add(now, -120, :second),
      accepted_at: DateTime.add(now, -60, :second),
      completed_at: if(status == "completed", do: now, else: nil),
      metadata: %{}
    })
  end

  defp ensure_driver_profile!(driver_id, category_id) do
    case Repo.get(Driver, driver_id) do
      nil ->
        user = Repo.get!(User, driver_id)

        VerificationFixtures.create_driver!(
          user: user,
          vehicle_category_id: category_id,
          subscription_status: "active",
          account_status: "active",
          verification_status: "approved",
          is_available: true
        )

      _driver ->
        :ok
    end
  end

  defp ensure_dispute_category!(slug) do
    case Repo.get_by(ReportCategory, slug: slug) do
      nil ->
        Repo.insert!(%ReportCategory{
          slug: slug,
          label: "Payment dispute",
          description: "Dispute category for payments.",
          applies_to: "both",
          severity_level_default: 3,
          recommended_action: "review",
          requires_immediate_attention: false,
          is_active: true,
          display_order: 1
        })

      category ->
        category
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
