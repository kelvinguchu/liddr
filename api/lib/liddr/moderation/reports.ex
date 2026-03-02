defmodule Liddr.Moderation.Reports do
  import Ecto.Query

  alias Liddr.Moderation.Categories
  alias Liddr.Moderation.Enforcements
  alias Liddr.Moderation.Query
  alias Liddr.Moderation.Report
  alias Liddr.Moderation.ReportCategory
  alias Liddr.Moderation.ReportReview
  alias Liddr.Repo

  @report_defaults %{
    "status" => "submitted",
    "source" => "in_app",
    "incident_type" => "conduct",
    "reporter_contact_opt_in" => false,
    "is_anonymous_to_reported" => true
  }
  @triage_statuses ~w(triaged under_review)
  @review_decisions ~w(needs_more_info no_action warning temporary_suspension permanent_ban escalate dismiss)
  @reviewable_report_statuses ~w(submitted triaged under_review)
  @report_sort_fields %{
    "inserted_at" => :inserted_at,
    "severity_level" => :severity_level,
    "status" => :status,
    "triaged_at" => :triaged_at,
    "resolved_at" => :resolved_at
  }

  def submit_report(attrs) do
    with {:ok, category} <- Categories.resolve_category(attrs),
         :ok <- ensure_category_scope(category, attrs),
         :ok <- ensure_not_self_report(attrs),
         {:ok, report_attrs} <- build_report_attrs(attrs, category) do
      %Report{}
      |> Report.create_changeset(report_attrs)
      |> Repo.insert()
    end
  end

  def list_reports(attrs \\ %{}) do
    from(r in Report)
    |> Query.maybe_filter_equals(:status, Query.get_value(attrs, :status))
    |> Query.maybe_filter_equals(
      :reported_user_id,
      Query.parse_integer(Query.get_value(attrs, :reported_user_id))
    )
    |> Query.maybe_filter_equals(
      :reporter_user_id,
      Query.parse_integer(Query.get_value(attrs, :reporter_user_id))
    )
    |> Query.maybe_filter_equals(
      :assigned_reviewer_user_id,
      Query.parse_integer(Query.get_value(attrs, :assigned_reviewer_user_id))
    )
    |> Query.maybe_filter_equals(
      :category_id,
      Query.parse_integer(Query.get_value(attrs, :category_id))
    )
    |> Query.maybe_filter_equals(
      :severity_level,
      Query.parse_integer(Query.get_value(attrs, :severity_level))
    )
    |> Query.apply_sort(attrs, @report_sort_fields, :inserted_at)
    |> Query.apply_pagination(attrs)
    |> Repo.all()
  end

  def triage_report(report_id, attrs, reviewer_user_id) do
    with {:ok, status} <- fetch_triage_status(attrs) do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      Repo.transaction(fn ->
        report =
          Repo.one(from r in Report, where: r.id == ^report_id, lock: "FOR UPDATE") ||
            Repo.rollback(:report_not_found)

        if report.status in @reviewable_report_statuses do
          update_attrs = %{
            status: status,
            triaged_at: report.triaged_at || now,
            assigned_reviewer_user_id: reviewer_user_id
          }

          report
          |> Ecto.Changeset.change(update_attrs)
          |> Repo.update()
          |> unwrap_or_rollback()
        else
          Repo.rollback(:report_not_triageable)
        end
      end)
      |> Query.unwrap_transaction_result()
    end
  end

  def review_report(report_id, attrs, reviewer_user_id) do
    with {:ok, decision} <- fetch_review_decision(attrs) do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      Repo.transaction(fn ->
        report =
          Repo.one(from r in Report, where: r.id == ^report_id, lock: "FOR UPDATE") ||
            Repo.rollback(:report_not_found)

        if report.status in @reviewable_report_statuses do
          review_attrs = %{
            report_id: report.id,
            reviewer_user_id: reviewer_user_id,
            decision: decision,
            severity_level: Query.get_value(attrs, :severity_level),
            reason_code: Query.get_value(attrs, :reason_code),
            notes: Query.get_value(attrs, :notes),
            decided_at: now,
            metadata: Query.get_value(attrs, :metadata) || %{}
          }

          review =
            %ReportReview{}
            |> ReportReview.create_changeset(review_attrs)
            |> Repo.insert()
            |> unwrap_or_rollback()

          update_attrs =
            report_update_for_decision(
              report,
              decision,
              now,
              review_attrs[:notes],
              reviewer_user_id
            )

          updated_report =
            report
            |> Ecto.Changeset.change(update_attrs)
            |> Repo.update()
            |> unwrap_or_rollback()

          enforcement =
            maybe_apply_review_enforcement!(
              updated_report,
              review,
              decision,
              attrs,
              reviewer_user_id,
              now
            )

          %{report: updated_report, review: review, enforcement: enforcement}
        else
          Repo.rollback(:report_not_reviewable)
        end
      end)
      |> Query.unwrap_transaction_result()
    end
  end

  defp fetch_triage_status(attrs) do
    status =
      attrs
      |> Query.get_value(:status)
      |> Query.normalize_text()

    if status in @triage_statuses, do: {:ok, status}, else: {:error, :invalid_triage_status}
  end

  defp fetch_review_decision(attrs) do
    decision =
      attrs
      |> Query.get_value(:decision)
      |> Query.normalize_text()

    if decision in @review_decisions,
      do: {:ok, decision},
      else: {:error, :invalid_review_decision}
  end

  defp ensure_category_scope(%ReportCategory{applies_to: "driver"}, attrs) do
    if is_nil(Query.get_value(attrs, :reported_driver_id)),
      do: {:error, :reported_driver_required},
      else: :ok
  end

  defp ensure_category_scope(_category, _attrs), do: :ok

  defp ensure_not_self_report(attrs) do
    reporter_user_id = Query.get_value(attrs, :reporter_user_id)
    reported_user_id = Query.get_value(attrs, :reported_user_id)

    if not is_nil(reporter_user_id) and reporter_user_id == reported_user_id do
      {:error, :self_report_not_allowed}
    else
      :ok
    end
  end

  defp build_report_attrs(attrs, category) do
    severity_level = Query.get_value(attrs, :severity_level) || category.severity_level_default

    built_attrs =
      attrs
      |> Map.new()
      |> Map.put("category_id", category.id)
      |> Map.put("severity_level", severity_level)
      |> Map.merge(@report_defaults, fn _key, provided, default ->
        if is_nil(provided), do: default, else: provided
      end)

    {:ok, built_attrs}
  end

  defp report_update_for_decision(report, "needs_more_info", now, _notes, reviewer_user_id) do
    %{
      status: "under_review",
      triaged_at: report.triaged_at || now,
      assigned_reviewer_user_id: reviewer_user_id
    }
  end

  defp report_update_for_decision(report, "escalate", now, _notes, reviewer_user_id) do
    %{
      status: "under_review",
      triaged_at: report.triaged_at || now,
      assigned_reviewer_user_id: reviewer_user_id,
      resolution_outcome: "escalated"
    }
  end

  defp report_update_for_decision(_report, "dismiss", now, notes, reviewer_user_id) do
    %{
      status: "dismissed",
      assigned_reviewer_user_id: reviewer_user_id,
      resolved_at: now,
      resolution_outcome: "no_action",
      resolution_summary: notes
    }
  end

  defp report_update_for_decision(_report, decision, now, notes, reviewer_user_id)
       when decision in ["no_action", "warning", "temporary_suspension", "permanent_ban"] do
    %{
      status: "resolved",
      assigned_reviewer_user_id: reviewer_user_id,
      resolved_at: now,
      resolution_outcome: decision,
      resolution_summary: notes
    }
  end

  defp unwrap_or_rollback({:ok, record}), do: record
  defp unwrap_or_rollback({:error, changeset}), do: Repo.rollback(changeset)

  defp maybe_apply_review_enforcement!(
         _report,
         _review,
         decision,
         _attrs,
         _reviewer_user_id,
         _now
       )
       when decision in ["needs_more_info", "no_action", "escalate", "dismiss"] do
    nil
  end

  defp maybe_apply_review_enforcement!(report, review, "warning", _attrs, reviewer_user_id, _now) do
    Enforcements.apply_enforcement_in_transaction!(%{
      "user_id" => report.reported_user_id,
      "report_id" => report.id,
      "actor_user_id" => reviewer_user_id,
      "scope" => "platform",
      "action" => "warning",
      "reason_code" => review.reason_code || "report_warning",
      "reason_text" => review.notes
    })
  end

  defp maybe_apply_review_enforcement!(
         report,
         review,
         "temporary_suspension",
         attrs,
         reviewer_user_id,
         now
       ) do
    ends_at = parse_enforcement_ends_at!(attrs, now)

    Enforcements.apply_enforcement_in_transaction!(%{
      "user_id" => report.reported_user_id,
      "report_id" => report.id,
      "actor_user_id" => reviewer_user_id,
      "scope" => "platform",
      "action" => "temporary_suspension",
      "reason_code" => review.reason_code || "report_temporary_suspension",
      "reason_text" => review.notes,
      "ends_at" => ends_at
    })
  end

  defp maybe_apply_review_enforcement!(
         report,
         review,
         "permanent_ban",
         _attrs,
         reviewer_user_id,
         _now
       ) do
    Enforcements.apply_enforcement_in_transaction!(%{
      "user_id" => report.reported_user_id,
      "report_id" => report.id,
      "actor_user_id" => reviewer_user_id,
      "scope" => "platform",
      "action" => "permanent_ban",
      "reason_code" => review.reason_code || "report_permanent_ban",
      "reason_text" => review.notes
    })
  end

  defp parse_enforcement_ends_at!(attrs, now) do
    raw_ends_at = Query.get_value(attrs, :ends_at) || Query.get_value(attrs, :enforcement_ends_at)
    normalized = Query.normalize_text(raw_ends_at)

    if is_nil(normalized), do: Repo.rollback(:missing_enforcement_ends_at)

    case DateTime.from_iso8601(normalized) do
      {:ok, parsed, _offset} ->
        if DateTime.compare(parsed, now) == :gt do
          parsed
        else
          Repo.rollback(:invalid_enforcement_ends_at)
        end

      _ ->
        Repo.rollback(:invalid_enforcement_ends_at)
    end
  end
end
