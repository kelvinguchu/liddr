defmodule Liddr.Ratings.Policy do
  @moduledoc false

  @default_policy [
    rating_window_hours: 24,
    rating_decay_per_day: 0.01,
    smoothing_prior_mean: 4.8,
    smoothing_prior_weight: 20,
    enforcement_recent_window_days: 30,
    enforcement_min_recent_ratings: 20,
    non_attributable_reason_tags: [
      "traffic",
      "app_issue",
      "gps_issue",
      "wrong_pickup_pin",
      "co_rider_behavior"
    ]
  ]

  def rating_window_hours, do: fetch(:rating_window_hours)
  def rating_decay_per_day, do: fetch(:rating_decay_per_day)
  def smoothing_prior_mean, do: fetch(:smoothing_prior_mean)
  def smoothing_prior_weight, do: fetch(:smoothing_prior_weight)
  def enforcement_recent_window_days, do: fetch(:enforcement_recent_window_days)
  def enforcement_min_recent_ratings, do: fetch(:enforcement_min_recent_ratings)
  def non_attributable_reason_tags, do: fetch(:non_attributable_reason_tags)

  def due_at(now), do: DateTime.add(now, rating_window_hours() * 3600, :second)

  def non_attributable_tag?(tag) when is_binary(tag) do
    normalized = normalize_tag(tag)
    normalized in non_attributable_reason_tags()
  end

  def non_attributable_tag?(_tag), do: false

  defp fetch(key) do
    policy =
      @default_policy
      |> Keyword.merge(Application.get_env(:liddr, __MODULE__, []))
      |> Keyword.update!(
        :non_attributable_reason_tags,
        &Enum.map(List.wrap(&1), fn tag -> normalize_tag(tag) end)
      )

    Keyword.fetch!(policy, key)
  end

  defp normalize_tag(tag) when is_binary(tag) do
    tag
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_tag(tag), do: tag |> to_string() |> normalize_tag()
end
