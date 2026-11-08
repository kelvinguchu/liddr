defmodule LiddrWeb.DisputeCompensationOpsControllerTest do
  use LiddrWeb.ConnCase, async: false

  alias Liddr.Accounts.Driver
  alias Liddr.Accounts.User
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

  test "ops marks compensation paid and blocks cancellation from paid state", %{conn: conn} do
    %{auth_conn: rider_conn, user_id: rider_id} = AuthFixtures.authenticate_rider!(conn)
    %{user_id: driver_id} = AuthFixtures.authenticate_driver!(conn)

    ops_auth = AuthFixtures.authenticate_ops!("ops-comp-flow@example.com")
    ops_conn = AuthFixtures.with_step_up!(ops_auth.auth_conn)
    ops_id = ops_auth.user_id

    ride = create_ride!(rider_id, driver_id)

    %{"data" => dispute} =
      post(rider_conn, "/api/disputes", %{
        "ride_id" => ride.id,
        "dispute_type" => "fare_dispute",
        "description" => "Fare mismatch detected."
      })
      |> json_response(201)

    %{"data" => %{"compensation" => compensation}} =
      post(ops_conn, "/api/ops/disputes/#{dispute["id"]}/resolve", %{
        "resolution_outcome" => "refund_partial",
        "resolution_amount_kes" => "70.00",
        "summary" => "Approved partial refund."
      })
      |> json_response(201)

    compensation_id = compensation["id"]

    assert %{"data" => %{"compensation" => paid}} =
             post(ops_conn, "/api/ops/disputes/compensations/#{compensation_id}/mark-paid", %{
               "reason_text" => "Refund sent via operations wallet.",
               "processing_reference" => "OPS-SETTLEMENT-9001",
               "processing_channel" => "wallet_credit"
             })
             |> json_response(200)

    assert paid["status"] == "paid"
    assert paid["processed_by_user_id"] == ops_id
    assert is_binary(paid["processed_at"])
    assert paid["processing_reference"] == "OPS-SETTLEMENT-9001"
    assert paid["processing_channel"] == "wallet_credit"

    assert %{"error" => %{"code" => "INVALID_COMPENSATION_TRANSITION"}} =
             post(ops_conn, "/api/ops/disputes/compensations/#{compensation_id}/cancel", %{
               "reason_text" => "Cancel attempt after paid."
             })
             |> json_response(422)

    assert %{"data" => %{"compensations" => rows}} =
             get(ops_conn, "/api/ops/disputes/compensations?status=paid")
             |> json_response(200)

    assert Enum.any?(rows, &(&1["id"] == compensation_id))
  end

  test "mark-paid requires processing reference", %{conn: conn} do
    %{auth_conn: rider_conn, user_id: rider_id} = AuthFixtures.authenticate_rider!(conn)
    %{user_id: driver_id} = AuthFixtures.authenticate_driver!(conn)

    ops_conn =
      AuthFixtures.authenticate_ops!("ops-comp-missing-ref@example.com")
      |> Map.fetch!(:auth_conn)
      |> AuthFixtures.with_step_up!()

    ride = create_ride!(rider_id, driver_id)

    %{"data" => dispute} =
      post(rider_conn, "/api/disputes", %{
        "ride_id" => ride.id,
        "dispute_type" => "fare_dispute",
        "description" => "Fare mismatch detected."
      })
      |> json_response(201)

    %{"data" => %{"compensation" => compensation}} =
      post(ops_conn, "/api/ops/disputes/#{dispute["id"]}/resolve", %{
        "resolution_outcome" => "refund_partial",
        "resolution_amount_kes" => "70.00",
        "summary" => "Approved partial refund."
      })
      |> json_response(201)

    assert %{"error" => %{"code" => "MISSING_COMPENSATION_PROCESSING_REFERENCE"}} =
             post(ops_conn, "/api/ops/disputes/compensations/#{compensation["id"]}/mark-paid", %{
               "processing_channel" => "wallet_credit"
             })
             |> json_response(422)
  end

  defp create_ride!(rider_id, driver_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    category_id = VerificationFixtures.insert_vehicle_category!()
    ensure_driver_profile!(driver_id, category_id)

    Repo.insert!(%Ride{
      rider_id: rider_id,
      driver_id: driver_id,
      vehicle_category_id: category_id,
      status: "completed",
      pickup_lat: Decimal.new("-1.2921000"),
      pickup_lng: Decimal.new("36.8219000"),
      dropoff_lat: Decimal.new("-1.3000000"),
      dropoff_lng: Decimal.new("36.8000000"),
      requested_at: DateTime.add(now, -120, :second),
      accepted_at: DateTime.add(now, -60, :second),
      completed_at: now,
      final_fare_kes: Decimal.new("500.00"),
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
