defmodule Liddr.Moderation.ActionRateLimiter do
  import Ecto.Query

  alias Liddr.Moderation.Report
  alias Liddr.Moderation.ReportReview
  alias Liddr.Repo

  @defaults %{
    dispute_create_window_seconds: 3_600,
    dispute_create_max_requests: 6,
    report_create_window_seconds: 3_600,
    report_create_max_requests: 12,
    report_triage_window_seconds: 3_600,
    report_triage_max_requests: 120,
    report_review_window_seconds: 3_600,
    report_review_max_requests: 80,
    ride_message_report_window_seconds: 3_600,
    ride_message_report_max_requests: 8,
    dispute_ops_resolution_window_seconds: 3_600,
    dispute_ops_resolution_max_requests: 30
  }

  def enforce_dispute_create(user_id, now \\ current_time()) do
    policy = policy()
    cutoff = DateTime.add(now, -policy.dispute_create_window_seconds, :second)

    count =
      Repo.aggregate(
        from(r in Report,
          where:
            r.reporter_user_id == ^user_id and
              r.inserted_at >= ^cutoff and
              r.context_type == "ride" and
              fragment("? ->> 'dispute_type' IS NOT NULL", r.metadata)
        ),
        :count,
        :id
      )

    if count >= policy.dispute_create_max_requests,
      do: {:error, :dispute_create_rate_limited},
      else: :ok
  end

  def enforce_report_create(user_id, now \\ current_time()) do
    policy = policy()
    cutoff = DateTime.add(now, -policy.report_create_window_seconds, :second)

    count =
      Repo.aggregate(
        from(r in Report,
          where:
            r.reporter_user_id == ^user_id and
              r.inserted_at >= ^cutoff and
              fragment("? ->> 'dispute_type' IS NULL", r.metadata)
        ),
        :count,
        :id
      )

    if count >= policy.report_create_max_requests,
      do: {:error, :report_create_rate_limited},
      else: :ok
  end

  def enforce_report_triage(user_id, now \\ current_time()) do
    policy = policy()
    cutoff = DateTime.add(now, -policy.report_triage_window_seconds, :second)

    count =
      Repo.aggregate(
        from(r in Report,
          where:
            r.assigned_reviewer_user_id == ^user_id and
              not is_nil(r.triaged_at) and
              r.triaged_at >= ^cutoff
        ),
        :count,
        :id
      )

    if count >= policy.report_triage_max_requests,
      do: {:error, :report_triage_rate_limited},
      else: :ok
  end

  def enforce_report_review(user_id, now \\ current_time()) do
    policy = policy()
    cutoff = DateTime.add(now, -policy.report_review_window_seconds, :second)

    count =
      Repo.aggregate(
        from(r in ReportReview,
          where:
            r.reviewer_user_id == ^user_id and
              r.inserted_at >= ^cutoff and
              fragment("? -> 'dispute_resolution' IS NULL", r.metadata)
        ),
        :count,
        :id
      )

    if count >= policy.report_review_max_requests,
      do: {:error, :report_review_rate_limited},
      else: :ok
  end

  def enforce_ride_message_report(user_id, now \\ current_time()) do
    policy = policy()
    cutoff = DateTime.add(now, -policy.ride_message_report_window_seconds, :second)

    count =
      Repo.aggregate(
        from(r in Report,
          where:
            r.reporter_user_id == ^user_id and
              r.inserted_at >= ^cutoff and
              r.context_type == "ride" and
              fragment("? LIKE 'ride_message:%'", r.context_reference)
        ),
        :count,
        :id
      )

    if count >= policy.ride_message_report_max_requests,
      do: {:error, :ride_message_report_rate_limited},
      else: :ok
  end

  def enforce_dispute_ops_resolution(user_id, now \\ current_time()) do
    policy = policy()
    cutoff = DateTime.add(now, -policy.dispute_ops_resolution_window_seconds, :second)

    count =
      Repo.aggregate(
        from(r in ReportReview,
          where:
            r.reviewer_user_id == ^user_id and
              r.inserted_at >= ^cutoff and
              fragment("? -> 'dispute_resolution' IS NOT NULL", r.metadata)
        ),
        :count,
        :id
      )

    if count >= policy.dispute_ops_resolution_max_requests,
      do: {:error, :ops_dispute_resolution_rate_limited},
      else: :ok
  end

  defp policy do
    configured = Application.get_env(:liddr, __MODULE__, [])

    %{
      dispute_create_window_seconds:
        resolve_int(configured, :dispute_create_window_seconds, 30, 86_400),
      dispute_create_max_requests:
        resolve_int(configured, :dispute_create_max_requests, 1, 10_000),
      report_create_window_seconds:
        resolve_int(configured, :report_create_window_seconds, 30, 86_400),
      report_create_max_requests: resolve_int(configured, :report_create_max_requests, 1, 10_000),
      report_triage_window_seconds:
        resolve_int(configured, :report_triage_window_seconds, 30, 86_400),
      report_triage_max_requests: resolve_int(configured, :report_triage_max_requests, 1, 10_000),
      report_review_window_seconds:
        resolve_int(configured, :report_review_window_seconds, 30, 86_400),
      report_review_max_requests: resolve_int(configured, :report_review_max_requests, 1, 10_000),
      ride_message_report_window_seconds:
        resolve_int(configured, :ride_message_report_window_seconds, 30, 86_400),
      ride_message_report_max_requests:
        resolve_int(configured, :ride_message_report_max_requests, 1, 10_000),
      dispute_ops_resolution_window_seconds:
        resolve_int(configured, :dispute_ops_resolution_window_seconds, 30, 86_400),
      dispute_ops_resolution_max_requests:
        resolve_int(configured, :dispute_ops_resolution_max_requests, 1, 10_000)
    }
  end

  defp resolve_int(configured, key, min, max) do
    default = Map.fetch!(@defaults, key)

    value =
      case Keyword.get(configured, key, default) do
        int when is_integer(int) -> int
        binary when is_binary(binary) -> parse_int_or_nil(binary)
        _ -> nil
      end

    resolved = if is_integer(value), do: value, else: default
    if resolved < min or resolved > max, do: default, else: resolved
  end

  defp parse_int_or_nil(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp current_time, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
