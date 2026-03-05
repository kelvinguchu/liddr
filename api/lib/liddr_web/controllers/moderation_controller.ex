defmodule LiddrWeb.ModerationController do
  use LiddrWeb, :controller

  alias Liddr.Moderation
  alias LiddrWeb.Idempotency
  alias LiddrWeb.ModerationErrors
  alias LiddrWeb.ModerationPayloads

  def list_reports(conn, params) do
    reports = Moderation.list_reports(params) |> Enum.map(&ModerationPayloads.report/1)
    json(conn, %{data: %{reports: reports}})
  end

  def triage_report(conn, %{"id" => report_id} = params) do
    reviewer_user_id = conn.assigns.current_user.id

    Idempotency.execute(
      conn,
      "moderation.report.triage:#{report_id}",
      params,
      fn ->
        case Moderation.triage_report(report_id, params, reviewer_user_id) do
          {:ok, report} -> {:ok, 200, %{data: ModerationPayloads.report(report)}}
          {:error, reason} -> {:error, reason}
        end
      end,
      &ModerationErrors.render/2
    )
  end

  def review_report(conn, %{"id" => report_id} = params) do
    reviewer_user_id = conn.assigns.current_user.id

    Idempotency.execute(
      conn,
      "moderation.report.review:#{report_id}",
      params,
      fn ->
        case Moderation.review_report(report_id, params, reviewer_user_id) do
          {:ok, %{report: report, review: review}} ->
            {:ok, 201,
             %{
               data: %{
                 report: ModerationPayloads.report(report),
                 review: ModerationPayloads.review(review)
               }
             }}

          {:error, reason} ->
            {:error, reason}
        end
      end,
      &ModerationErrors.render/2
    )
  end

  def create_enforcement(conn, params) do
    actor_id = conn.assigns.current_user.id
    payload = Map.put(params, "actor_user_id", actor_id)

    Idempotency.execute(
      conn,
      "moderation.enforcement.create",
      payload,
      fn ->
        case Moderation.apply_enforcement(payload) do
          {:ok, enforcement} -> {:ok, 201, %{data: ModerationPayloads.enforcement(enforcement)}}
          {:error, reason} -> {:error, reason}
        end
      end,
      &ModerationErrors.render/2
    )
  end

  def list_enforcements(conn, params) do
    enforcements =
      Moderation.list_enforcements(params) |> Enum.map(&ModerationPayloads.enforcement/1)

    json(conn, %{data: %{enforcements: enforcements}})
  end

  def enforcement_metrics(conn, params) do
    case Moderation.enforcement_metrics(params) do
      {:ok, metrics} ->
        json(conn, %{data: metrics})

      {:error, reason} ->
        ModerationErrors.render(conn, reason)
    end
  end

  def reconcile_enforcements(conn, params) do
    Idempotency.execute(
      conn,
      "moderation.enforcement.reconcile_expired",
      params,
      fn ->
        with {:ok, limit} <- ModerationErrors.parse_reconciliation_limit(params),
             {:ok, results} <- Moderation.expire_due_temporary_suspensions(%{limit: limit}) do
          expired_count = Enum.count(results, &(&1.status == "expired"))

          {:ok, 200,
           %{
             data: %{
               processed: length(results),
               expired: expired_count,
               results: results
             }
           }}
        else
          {:error, reason} -> {:error, reason}
        end
      end,
      &ModerationErrors.render/2
    )
  end
end
