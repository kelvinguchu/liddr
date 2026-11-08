defmodule Liddr.Disputes.Compensations do
  import Ecto.Query

  alias Liddr.Disputes.Compensation
  alias Liddr.Disputes.CompensationsSupport
  alias Liddr.Moderation.Query
  alias Liddr.Moderation.Report
  alias Liddr.Repo
  alias Liddr.Rides.Ride
  alias Liddr.Rides.RideQuote

  @compensation_outcomes ~w(refund_full refund_partial credit_note)
  @sort_fields %{"inserted_at" => :inserted_at, "status" => :status, "amount_kes" => :amount_kes}

  def create_for_outcome(%Report{} = report, outcome, attrs, actor_user_id) do
    if outcome in @compensation_outcomes do
      with {:ok, ride_id, ride} <- fetch_report_ride(report),
           {:ok, amount_kes} <- resolve_amount_kes(outcome, attrs, ride) do
        compensation_attrs = %{
          "report_id" => report.id,
          "ride_id" => ride_id,
          "beneficiary_user_id" => report.reporter_user_id,
          "counterparty_user_id" => report.reported_user_id,
          "actor_user_id" => actor_user_id,
          "compensation_type" => outcome,
          "status" => "approved",
          "amount_kes" => amount_kes,
          "currency" => "KES",
          "reason_code" => "dispute_#{outcome}",
          "reason_text" => Query.get_value(attrs, :summary),
          "metadata" => %{
            "resolution_outcome" => outcome,
            "report_status" => report.status,
            "source" => "ops_dispute_resolution"
          }
        }

        insert_or_get_existing(compensation_attrs)
      end
    else
      {:ok, nil}
    end
  end

  def list_for_user(user_id, attrs \\ %{}) do
    Compensation
    |> where([c], c.beneficiary_user_id == ^user_id)
    |> Query.maybe_filter_equals(:status, Query.get_value(attrs, :status))
    |> Query.maybe_filter_equals(:compensation_type, Query.get_value(attrs, :compensation_type))
    |> Query.apply_sort(attrs, @sort_fields, :inserted_at)
    |> Query.apply_pagination(attrs)
    |> Repo.all()
  end

  def list_for_ops(attrs \\ %{}) do
    Compensation
    |> Query.maybe_filter_equals(:status, Query.get_value(attrs, :status))
    |> Query.maybe_filter_equals(:compensation_type, Query.get_value(attrs, :compensation_type))
    |> Query.maybe_filter_equals(
      :beneficiary_user_id,
      Query.parse_integer(Query.get_value(attrs, :beneficiary_user_id))
    )
    |> Query.maybe_filter_equals(
      :report_id,
      Query.parse_integer(Query.get_value(attrs, :report_id))
    )
    |> Query.maybe_filter_equals(
      :ride_id,
      Query.parse_integer(Query.get_value(attrs, :ride_id))
    )
    |> Query.maybe_filter_equals(
      :processed_by_user_id,
      Query.parse_integer(Query.get_value(attrs, :processed_by_user_id))
    )
    |> Query.maybe_filter_equals(:processing_channel, Query.get_value(attrs, :processing_channel))
    |> Query.apply_sort(attrs, @sort_fields, :inserted_at)
    |> Query.apply_pagination(attrs)
    |> Repo.all()
  end

  def mark_paid(compensation_id, actor_user_id, attrs \\ %{}) do
    transition_status(compensation_id, actor_user_id, "paid", attrs)
  end

  def cancel(compensation_id, actor_user_id, attrs \\ %{}) do
    transition_status(compensation_id, actor_user_id, "cancelled", attrs)
  end

  defp fetch_report_ride(%Report{context_reference: context_reference}) do
    with {:ok, ride_id} <-
           CompensationsSupport.parse_positive_integer(
             context_reference,
             :invalid_dispute_ride_reference
           ) do
      case Repo.get(Ride, ride_id) do
        %Ride{} = ride -> {:ok, ride_id, ride}
        nil -> {:error, :invalid_dispute_ride_reference}
      end
    end
  end

  defp resolve_amount_kes(outcome, attrs, %Ride{} = ride) do
    requested =
      attrs
      |> Query.get_value(:resolution_amount_kes)
      |> CompensationsSupport.parse_positive_decimal()

    with {:ok, fare} <- refundable_fare(ride) do
      CompensationsSupport.resolve_amount(outcome, requested, fare)
    end
  end

  defp refundable_fare(%Ride{} = ride) do
    case CompensationsSupport.positive_fare(ride.final_fare_kes) || quoted_fare(ride.quote_id) do
      nil -> {:error, :refund_fare_unavailable}
      fare -> {:ok, fare}
    end
  end

  defp quoted_fare(nil), do: nil

  defp quoted_fare(quote_id) do
    case Repo.get(RideQuote, quote_id) do
      %RideQuote{final_fare_kes: fare} -> CompensationsSupport.positive_fare(fare)
      nil -> nil
    end
  end

  defp insert_or_get_existing(attrs) do
    case %Compensation{} |> Compensation.create_changeset(attrs) |> Repo.insert() do
      {:ok, compensation} ->
        {:ok, compensation}

      {:error, %Ecto.Changeset{} = changeset} ->
        if unique_report_constraint?(changeset) do
          case Repo.get_by(Compensation, report_id: attrs["report_id"]) do
            %Compensation{} = existing -> {:ok, existing}
            nil -> {:error, :dispute_compensation_conflict}
          end
        else
          {:error, changeset}
        end
    end
  end

  defp transition_status(compensation_id, actor_user_id, target_status, attrs) do
    with {:ok, parsed_id} <-
           CompensationsSupport.parse_positive_integer(
             compensation_id,
             :invalid_compensation_id
           ) do
      Repo.transaction(fn ->
        compensation =
          Repo.one(from c in Compensation, where: c.id == ^parsed_id, lock: "FOR UPDATE") ||
            Repo.rollback(:compensation_not_found)

        apply_transition(compensation, actor_user_id, target_status, attrs)
      end)
      |> Query.unwrap_transaction_result()
    end
  end

  defp apply_transition(%Compensation{status: status} = compensation, _actor_id, status, _attrs),
    do: compensation

  defp apply_transition(
         %Compensation{status: "approved"} = compensation,
         actor_user_id,
         target,
         attrs
       ) do
    with {:ok, processing_reference} <-
           CompensationsSupport.resolve_processing_reference(target, attrs),
         {:ok, processing_channel} <- CompensationsSupport.resolve_processing_channel(attrs) do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      reason_text =
        CompensationsSupport.normalize_text(
          Query.get_value(attrs, :reason_text) || Query.get_value(attrs, :notes)
        )

      processing_event =
        CompensationsSupport.processing_event(
          compensation.status,
          target,
          actor_user_id,
          now,
          reason_text,
          processing_reference,
          processing_channel
        )

      metadata =
        compensation.metadata
        |> CompensationsSupport.normalize_metadata()
        |> Map.put("last_processing_event", processing_event)

      updates = %{
        status: target,
        processed_at: now,
        processed_by_user_id: actor_user_id,
        processing_reference: processing_reference,
        processing_channel: processing_channel,
        metadata: metadata
      }

      updates =
        if is_binary(reason_text) and reason_text != "" do
          Map.put(updates, :reason_text, reason_text)
        else
          updates
        end

      compensation
      |> Compensation.transition_changeset(updates)
      |> Repo.update()
      |> unwrap_or_rollback()
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp apply_transition(_compensation, _actor_user_id, _target_status, _attrs),
    do: Repo.rollback(:invalid_compensation_transition)

  defp unique_report_constraint?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn
      {:report_id, {_message, opts}} -> opts[:constraint] == :unique
      _ -> false
    end)
  end

  defp unwrap_or_rollback({:ok, value}), do: value
  defp unwrap_or_rollback({:error, changeset}), do: Repo.rollback(changeset)
end
