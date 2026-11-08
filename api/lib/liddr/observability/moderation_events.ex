defmodule Liddr.Observability.ModerationEvents do
  @moduledoc false

  @event_report_triage_rate_limited [:liddr, :moderation, :report, :triage, :rate_limited]
  @event_report_review_rate_limited [:liddr, :moderation, :report, :review, :rate_limited]
  @event_report_triage_success [:liddr, :moderation, :report, :triage, :success]
  @event_report_review_success [:liddr, :moderation, :report, :review, :success]
  @event_dispute_create_success [:liddr, :disputes, :create, :success]
  @event_dispute_resolve_success [:liddr, :disputes, :resolve, :success]
  @allowed_metadata_keys %{
    "decision" => :decision,
    "dispute_type" => :dispute_type,
    "report_id" => :report_id,
    "reporter_user_id" => :reporter_user_id,
    "resolution_outcome" => :resolution_outcome,
    "reviewer_user_id" => :reviewer_user_id,
    "status" => :status
  }

  def event_names do
    [
      @event_report_triage_rate_limited,
      @event_report_review_rate_limited,
      @event_report_triage_success,
      @event_report_review_success,
      @event_dispute_create_success,
      @event_dispute_resolve_success
    ]
  end

  def report_triage_rate_limited(metadata \\ %{}),
    do: emit(@event_report_triage_rate_limited, metadata)

  def report_review_rate_limited(metadata \\ %{}),
    do: emit(@event_report_review_rate_limited, metadata)

  def report_triage_success(metadata \\ %{}),
    do: emit(@event_report_triage_success, metadata)

  def report_review_success(metadata \\ %{}),
    do: emit(@event_report_review_success, metadata)

  def dispute_create_success(metadata \\ %{}),
    do: emit(@event_dispute_create_success, metadata)

  def dispute_resolve_success(metadata \\ %{}),
    do: emit(@event_dispute_resolve_success, metadata)

  defp emit(event_name, metadata) when is_list(event_name) do
    :telemetry.execute(event_name, %{count: 1}, normalize_metadata(metadata))
  end

  defp normalize_metadata(metadata) when is_map(metadata) do
    metadata
    |> Enum.map(fn {key, value} -> {normalize_key(key), normalize_value(value)} end)
    |> Map.new()
  end

  defp normalize_metadata(_metadata), do: %{}

  defp normalize_key(key) when is_atom(key), do: key

  defp normalize_key(key) when is_binary(key) do
    Map.get(@allowed_metadata_keys, String.trim(key), :unknown)
  end

  defp normalize_key(_key), do: :unknown

  defp normalize_value(nil), do: "unknown"

  defp normalize_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_value(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_value(value) when is_float(value), do: Float.to_string(value)

  defp normalize_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> "unknown"
      normalized -> normalized
    end
  end

  defp normalize_value(_value), do: "unknown"
end
