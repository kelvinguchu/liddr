defmodule Liddr.Disputes.CompensationsTest do
  use Liddr.DataCase, async: false

  alias Liddr.Disputes
  alias Liddr.Disputes.Cases
  alias Liddr.Disputes.Compensation
  alias Liddr.Disputes.Compensations
  alias Liddr.Moderation.Report
  alias Liddr.Moderation.ReportCategory
  alias Liddr.Repo
  alias Liddr.Rides.Ride
  alias Liddr.VerificationFixtures

  setup do
    ensure_dispute_category!("payment_dispute")
    :ok
  end

  test "create_for_outcome deduplicates repeated insert attempts for same dispute" do
    %{rider: rider, driver: _driver_user, ops: ops_user, ride: ride} = create_dispute_fixture!()

    {:ok, report} =
      Disputes.submit_for_ride(rider.id, %{
        "ride_id" => ride.id,
        "dispute_type" => "fare_dispute",
        "description" => "Mismatch between quote and charged fare."
      })

    persisted_report = Repo.get!(Report, report.id)
    attrs = %{"resolution_amount_kes" => "70.00", "summary" => "Partial refund approved"}

    {:ok, first} =
      Compensations.create_for_outcome(persisted_report, "refund_partial", attrs, ops_user.id)

    {:ok, second} =
      Compensations.create_for_outcome(persisted_report, "refund_partial", attrs, ops_user.id)

    assert first.id == second.id

    assert 1 ==
             Repo.aggregate(
               from(c in Compensation, where: c.report_id == ^report.id),
               :count,
               :id
             )
  end

  test "resolve_for_ops creates compensation once and blocks second resolve" do
    %{rider: rider, driver: _driver_user, ops: ops_user, ride: ride} = create_dispute_fixture!()

    {:ok, report} =
      Disputes.submit_for_ride(rider.id, %{
        "ride_id" => ride.id,
        "dispute_type" => "fare_dispute",
        "description" => "Charged amount was incorrect."
      })

    params = %{
      "resolution_outcome" => "refund_partial",
      "resolution_amount_kes" => "50.00",
      "summary" => "Compensation approved after review."
    }

    assert {:ok, payload} = Cases.resolve_for_ops(report.id, ops_user.id, params)
    assert payload.compensation.compensation_type == "refund_partial"
    assert payload.compensation.amount_kes == Decimal.new("50.00")

    assert {:error, :report_not_reviewable} =
             Cases.resolve_for_ops(report.id, ops_user.id, params)

    assert 1 ==
             Repo.aggregate(
               from(c in Compensation, where: c.report_id == ^report.id),
               :count,
               :id
             )
  end

  test "compensation lifecycle allows approved->paid and blocks paid->cancelled" do
    %{rider: rider, driver: _driver_user, ops: ops_user, ride: ride} = create_dispute_fixture!()

    {:ok, report} =
      Disputes.submit_for_ride(rider.id, %{
        "ride_id" => ride.id,
        "dispute_type" => "fare_dispute",
        "description" => "Charged amount was incorrect."
      })

    params = %{
      "resolution_outcome" => "refund_partial",
      "resolution_amount_kes" => "50.00",
      "summary" => "Compensation approved after review."
    }

    {:ok, payload} = Cases.resolve_for_ops(report.id, ops_user.id, params)
    compensation = payload.compensation

    {:ok, paid} =
      Compensations.mark_paid(compensation.id, ops_user.id, %{
        "reason_text" => "Paid out",
        "processing_reference" => "OPS-PAYOUT-1001",
        "processing_channel" => "wallet_credit"
      })

    assert paid.status == "paid"
    assert paid.processed_by_user_id == ops_user.id
    assert %DateTime{} = paid.processed_at
    assert paid.processing_reference == "OPS-PAYOUT-1001"
    assert paid.processing_channel == "wallet_credit"

    assert {:error, :invalid_compensation_transition} =
             Compensations.cancel(compensation.id, ops_user.id, %{"reason_text" => "Too late"})
  end

  test "mark_paid requires processing reference and valid processing channel" do
    %{rider: rider, driver: _driver_user, ops: ops_user, ride: ride} = create_dispute_fixture!()

    {:ok, report} =
      Disputes.submit_for_ride(rider.id, %{
        "ride_id" => ride.id,
        "dispute_type" => "fare_dispute",
        "description" => "Charged amount was incorrect."
      })

    params = %{
      "resolution_outcome" => "refund_partial",
      "resolution_amount_kes" => "50.00",
      "summary" => "Compensation approved after review."
    }

    {:ok, payload} = Cases.resolve_for_ops(report.id, ops_user.id, params)
    compensation = payload.compensation

    assert {:error, :missing_compensation_processing_reference} =
             Compensations.mark_paid(compensation.id, ops_user.id, %{
               "processing_channel" => "wallet_credit"
             })

    assert {:error, :invalid_compensation_processing_channel} =
             Compensations.mark_paid(compensation.id, ops_user.id, %{
               "processing_reference" => "OPS-PAYOUT-1002",
               "processing_channel" => "unsupported_channel"
             })
  end

  test "refund_full resolves amount from final fare when explicit amount is missing" do
    %{rider: rider, ops: ops_user, ride: ride} = create_dispute_fixture!()

    {:ok, report} =
      Disputes.submit_for_ride(rider.id, %{
        "ride_id" => ride.id,
        "dispute_type" => "fare_dispute",
        "description" => "Fare should be fully refunded."
      })

    {:ok, payload} =
      Cases.resolve_for_ops(report.id, ops_user.id, %{
        "resolution_outcome" => "refund_full",
        "summary" => "Approved full refund."
      })

    assert payload.compensation.compensation_type == "refund_full"
    assert payload.compensation.amount_kes == Decimal.new("200.00")
  end

  test "refund_full requires amount when final fare is unavailable" do
    %{rider: rider, ops: ops_user, ride: ride} = create_dispute_fixture!(final_fare_kes: nil)

    {:ok, report} =
      Disputes.submit_for_ride(rider.id, %{
        "ride_id" => ride.id,
        "dispute_type" => "fare_dispute",
        "description" => "Fare should be fully refunded."
      })

    assert {:error, :missing_resolution_amount} =
             Cases.resolve_for_ops(report.id, ops_user.id, %{
               "resolution_outcome" => "refund_full",
               "summary" => "Approved full refund."
             })
  end

  defp create_dispute_fixture!(overrides \\ %{}) do
    normalized_overrides =
      case overrides do
        list when is_list(list) -> Enum.into(list, %{})
        map when is_map(map) -> map
        _ -> %{}
      end

    rider = VerificationFixtures.create_user!()
    driver_user = VerificationFixtures.create_user!()

    ops_user =
      VerificationFixtures.create_user!(%{email: VerificationFixtures.unique_email("ops")})

    category_id = VerificationFixtures.insert_vehicle_category!()

    VerificationFixtures.create_driver!(
      user: driver_user,
      vehicle_category_id: category_id,
      subscription_status: "active",
      account_status: "active",
      verification_status: "approved",
      is_available: true
    )

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    ride =
      Repo.insert!(%Ride{
        rider_id: rider.id,
        driver_id: driver_user.id,
        vehicle_category_id: category_id,
        status: "completed",
        pickup_lat: Decimal.new("-1.2921000"),
        pickup_lng: Decimal.new("36.8219000"),
        dropoff_lat: Decimal.new("-1.3000000"),
        dropoff_lng: Decimal.new("36.8000000"),
        requested_at: DateTime.add(now, -300, :second),
        accepted_at: DateTime.add(now, -240, :second),
        completed_at: now,
        final_fare_kes: Map.get(normalized_overrides, :final_fare_kes, Decimal.new("200.00")),
        metadata: %{}
      })

    %{rider: rider, driver: driver_user, ops: ops_user, ride: ride}
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
end
