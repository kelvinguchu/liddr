defmodule LiddrWeb.DisputeOpsController do
  use LiddrWeb, :controller

  alias Liddr.Disputes
  alias Liddr.Observability.ModerationEvents
  alias LiddrWeb.DisputeErrors
  alias LiddrWeb.DisputePayloads
  alias LiddrWeb.Idempotency

  def index(conn, params) do
    disputes = Disputes.list_for_ops(params) |> Enum.map(&DisputePayloads.report/1)
    json(conn, %{data: %{disputes: disputes}})
  end

  def compensations(conn, params) do
    compensations =
      Disputes.list_compensations_for_ops(params)
      |> Enum.map(&DisputePayloads.compensation/1)

    json(conn, %{data: %{compensations: compensations}})
  end

  def resolve(conn, %{"id" => report_id} = params) do
    reviewer_user_id = conn.assigns.current_user.id

    Idempotency.execute(
      conn,
      "ops.dispute.resolve:#{report_id}",
      params,
      fn ->
        with :ok <- Disputes.enforce_ops_resolution_rate_limit(reviewer_user_id),
             {:ok, payload} <- Disputes.resolve_for_ops(report_id, reviewer_user_id, params) do
          ModerationEvents.dispute_resolve_success(%{
            reviewer_user_id: reviewer_user_id,
            resolution_outcome: payload.resolution_outcome
          })

          {:ok, 201, %{data: DisputePayloads.resolution(payload)}}
        else
          {:error, reason} -> {:error, reason}
        end
      end,
      &DisputeErrors.render/2
    )
  end

  def mark_compensation_paid(conn, %{"id" => compensation_id} = params) do
    actor_user_id = conn.assigns.current_user.id

    Idempotency.execute(
      conn,
      "ops.dispute.compensation.pay:#{compensation_id}",
      params,
      fn ->
        case Disputes.mark_compensation_paid(compensation_id, actor_user_id, params) do
          {:ok, compensation} ->
            {:ok, 200, %{data: %{compensation: DisputePayloads.compensation(compensation)}}}

          {:error, reason} ->
            {:error, reason}
        end
      end,
      &DisputeErrors.render/2
    )
  end

  def cancel_compensation(conn, %{"id" => compensation_id} = params) do
    actor_user_id = conn.assigns.current_user.id

    Idempotency.execute(
      conn,
      "ops.dispute.compensation.cancel:#{compensation_id}",
      params,
      fn ->
        case Disputes.cancel_compensation(compensation_id, actor_user_id, params) do
          {:ok, compensation} ->
            {:ok, 200, %{data: %{compensation: DisputePayloads.compensation(compensation)}}}

          {:error, reason} ->
            {:error, reason}
        end
      end,
      &DisputeErrors.render/2
    )
  end
end
