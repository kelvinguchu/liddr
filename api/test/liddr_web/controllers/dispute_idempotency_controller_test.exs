defmodule LiddrWeb.DisputeIdempotencyControllerTest do
  use LiddrWeb.ConnCase, async: false

  import Ecto.Query

  alias Liddr.Accounts.Driver
  alias Liddr.Accounts.User
  alias Liddr.Disputes.Compensation
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

  test "ops resolve dispute replays idempotent response and does not double-credit", %{conn: conn} do
    %{auth_conn: rider_conn, user_id: rider_id} = AuthFixtures.authenticate_rider!(conn)
    %{user_id: driver_id} = AuthFixtures.authenticate_driver!(conn)
    %{auth_conn: ops_conn} = AuthFixtures.authenticate_ops!("ops-dispute-idem@example.com")
    step_up_token = AuthFixtures.issue_step_up_token!(ops_conn)
    ops_conn = put_req_header(ops_conn, "x-step-up-token", step_up_token)
    ride = create_ride!(rider_id, driver_id)

    %{"data" => dispute} =
      post(rider_conn, "/api/disputes", %{
        "ride_id" => ride.id,
        "dispute_type" => "fare_dispute",
        "description" => "Charged above expected amount."
      })
      |> json_response(201)

    key = "ops-dispute-resolve-#{System.unique_integer([:positive])}"
    payload = %{"resolution_outcome" => "refund_partial", "resolution_amount_kes" => "40.00"}

    first =
      ops_conn
      |> put_req_header("idempotency-key", key)
      |> post("/api/ops/disputes/#{dispute["id"]}/resolve", payload)
      |> json_response(201)

    second =
      ops_conn
      |> recycle()
      |> put_req_header("x-step-up-token", step_up_token)
      |> put_req_header("idempotency-key", key)
      |> post("/api/ops/disputes/#{dispute["id"]}/resolve", payload)
      |> json_response(201)

    assert first == second

    assert 1 ==
             Repo.aggregate(
               from(c in Compensation, where: c.report_id == ^dispute["id"]),
               :count,
               :id
             )
  end

  test "ops mark-paid compensation replays idempotent response", %{conn: conn} do
    %{auth_conn: rider_conn, user_id: rider_id} = AuthFixtures.authenticate_rider!(conn)
    %{user_id: driver_id} = AuthFixtures.authenticate_driver!(conn)
    %{auth_conn: ops_conn} = AuthFixtures.authenticate_ops!("ops-dispute-pay-idem@example.com")
    step_up_token = AuthFixtures.issue_step_up_token!(ops_conn)
    ops_conn = put_req_header(ops_conn, "x-step-up-token", step_up_token)
    ride = create_ride!(rider_id, driver_id)

    %{"data" => dispute} =
      post(rider_conn, "/api/disputes", %{
        "ride_id" => ride.id,
        "dispute_type" => "fare_dispute",
        "description" => "Charged above expected amount."
      })
      |> json_response(201)

    %{"data" => %{"compensation" => compensation}} =
      post(ops_conn, "/api/ops/disputes/#{dispute["id"]}/resolve", %{
        "resolution_outcome" => "refund_partial",
        "resolution_amount_kes" => "40.00"
      })
      |> json_response(201)

    compensation_id = compensation["id"]
    key = "ops-dispute-pay-#{System.unique_integer([:positive])}"

    first =
      ops_conn
      |> recycle()
      |> put_req_header("x-step-up-token", step_up_token)
      |> put_req_header("idempotency-key", key)
      |> post("/api/ops/disputes/compensations/#{compensation_id}/mark-paid", %{
        "reason_text" => "Payout executed.",
        "processing_reference" => "OPS-PAYOUT-IDEM-1001",
        "processing_channel" => "wallet_credit"
      })
      |> json_response(200)

    second =
      ops_conn
      |> recycle()
      |> put_req_header("x-step-up-token", step_up_token)
      |> put_req_header("idempotency-key", key)
      |> post("/api/ops/disputes/compensations/#{compensation_id}/mark-paid", %{
        "reason_text" => "Payout executed.",
        "processing_reference" => "OPS-PAYOUT-IDEM-1001",
        "processing_channel" => "wallet_credit"
      })
      |> json_response(200)

    assert first == second
    assert first["data"]["compensation"]["status"] == "paid"
  end

  defp create_ride!(rider_id, driver_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    category_id = VerificationFixtures.insert_vehicle_category!()
    ensure_driver_profile!(driver_id, category_id)

    Repo.insert!(%Ride{
      rider_id: rider_id,
      driver_id: driver_id,
      vehicle_category_id: category_id,
      status: "accepted",
      pickup_lat: Decimal.new("-1.2921000"),
      pickup_lng: Decimal.new("36.8219000"),
      dropoff_lat: Decimal.new("-1.3000000"),
      dropoff_lng: Decimal.new("36.8000000"),
      requested_at: DateTime.add(now, -120, :second),
      accepted_at: DateTime.add(now, -60, :second),
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
