defmodule Liddr.Ratings.Ops do
  import Ecto.Query

  alias Liddr.Ratings.Guardrails
  alias Liddr.Ratings.Inclusion
  alias Liddr.Ratings.Rating
  alias Liddr.Ratings.Scoring
  alias Liddr.Repo
  alias Liddr.Rides.Events
  alias Liddr.Subscriptions.PaymentUtils

  @default_limit 100
  @max_limit 500

  def list_ratings(attrs \\ %{}) do
    query =
      from r in Rating,
        order_by: [desc: r.id],
        limit: ^resolve_limit(attrs)

    query =
      query
      |> maybe_filter_rated_user(attrs)
      |> maybe_filter_ride(attrs)
      |> maybe_filter_before_id(attrs)
      |> maybe_filter_excluded_only(attrs)

    {:ok, Repo.all(query)}
  end

  def list_excluded_ratings(attrs \\ %{}) do
    attrs
    |> Map.new()
    |> Map.put("excluded_only", true)
    |> list_ratings()
  end

  def nullify_rating(rating_id, attrs, actor_user_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    with {:ok, parsed_rating_id} <- parse_positive_integer(rating_id, :invalid_rating_id),
         {:ok, reason_code} <- parse_required_text(attrs, :reason_code, :missing_reason_code) do
      Repo.transaction(fn ->
        rating = fetch_rating_for_update!(parsed_rating_id)

        if rating.nullified_at do
          Repo.rollback(:rating_already_nullified)
        end

        updated_rating =
          rating
          |> Rating.create_changeset(%{
            "include_in_score" => false,
            "exclusion_reason_code" => "ops_nullified",
            "nullified_at" => now,
            "nullified_by_user_id" => actor_user_id,
            "nullification_reason_code" => reason_code,
            "nullification_note" => parse_optional_text(attrs, :note)
          })
          |> Repo.update()
          |> unwrap_or_rollback()

        stats = Scoring.recalculate_user_score!(updated_rating.rated_user_id, now)

        _ =
          Events.record_event(updated_rating.ride_id, "ride_rating_nullified", now,
            actor_user_id: actor_user_id,
            payload: %{
              "rating_id" => updated_rating.id,
              "reason_code" => reason_code,
              "include_in_score" => updated_rating.include_in_score
            }
          )
          |> unwrap_or_rollback()

        %{
          rating: updated_rating,
          rated_user_stats: stats,
          guardrails: Guardrails.enforcement_snapshot_for_user(updated_rating.rated_user_id, now)
        }
      end)
      |> unwrap_transaction_result()
    end
  end

  def reinstate_rating(rating_id, _attrs, actor_user_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    with {:ok, parsed_rating_id} <- parse_positive_integer(rating_id, :invalid_rating_id) do
      Repo.transaction(fn ->
        rating = fetch_rating_for_update!(parsed_rating_id)

        if is_nil(rating.nullified_at) do
          Repo.rollback(:rating_not_nullified)
        end

        {include_in_score, exclusion_reason_code} =
          Inclusion.decision(rating.score, rating.reason_tags || [])

        updated_rating =
          rating
          |> Rating.create_changeset(%{
            "include_in_score" => include_in_score,
            "exclusion_reason_code" => exclusion_reason_code,
            "nullified_at" => nil,
            "nullified_by_user_id" => nil,
            "nullification_reason_code" => nil,
            "nullification_note" => nil
          })
          |> Repo.update()
          |> unwrap_or_rollback()

        stats = Scoring.recalculate_user_score!(updated_rating.rated_user_id, now)

        _ =
          Events.record_event(updated_rating.ride_id, "ride_rating_reinstated", now,
            actor_user_id: actor_user_id,
            payload: %{
              "rating_id" => updated_rating.id,
              "include_in_score" => include_in_score,
              "exclusion_reason_code" => exclusion_reason_code
            }
          )
          |> unwrap_or_rollback()

        %{
          rating: updated_rating,
          rated_user_stats: stats,
          guardrails: Guardrails.enforcement_snapshot_for_user(updated_rating.rated_user_id, now)
        }
      end)
      |> unwrap_transaction_result()
    end
  end

  defp fetch_rating_for_update!(rating_id) do
    Repo.one(from r in Rating, where: r.id == ^rating_id, lock: "FOR UPDATE") ||
      Repo.rollback(:rating_not_found)
  end

  defp maybe_filter_rated_user(query, attrs) do
    case parse_positive_integer(
           PaymentUtils.get_value(attrs, :rated_user_id),
           :invalid_rated_user_id
         ) do
      {:ok, rated_user_id} -> from r in query, where: r.rated_user_id == ^rated_user_id
      _ -> query
    end
  end

  defp maybe_filter_ride(query, attrs) do
    case parse_positive_integer(PaymentUtils.get_value(attrs, :ride_id), :invalid_ride_id) do
      {:ok, ride_id} -> from r in query, where: r.ride_id == ^ride_id
      _ -> query
    end
  end

  defp maybe_filter_before_id(query, attrs) do
    case parse_positive_integer(PaymentUtils.get_value(attrs, :before_id), :invalid_before_id) do
      {:ok, before_id} -> from r in query, where: r.id < ^before_id
      _ -> query
    end
  end

  defp maybe_filter_excluded_only(query, attrs) do
    excluded_only? =
      attrs
      |> PaymentUtils.get_value(:excluded_only)
      |> parse_boolean(false)

    if excluded_only? do
      from r in query,
        where: r.include_in_score == false or not is_nil(r.nullified_at)
    else
      query
    end
  end

  defp resolve_limit(attrs) do
    attrs
    |> PaymentUtils.get_value(:limit)
    |> parse_positive_integer(nil)
    |> case do
      {:ok, parsed} when parsed > @max_limit -> @max_limit
      {:ok, parsed} -> parsed
      _ -> @default_limit
    end
  end

  defp parse_required_text(attrs, key, missing_reason) do
    case parse_optional_text(attrs, key) do
      nil -> {:error, missing_reason}
      text -> {:ok, text}
    end
  end

  defp parse_optional_text(attrs, key) do
    attrs
    |> PaymentUtils.get_value(key)
    |> PaymentUtils.normalize_text()
  end

  defp parse_positive_integer(value, _error_reason) when is_integer(value) and value > 0,
    do: {:ok, value}

  defp parse_positive_integer(value, error_reason) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> {:error, error_reason}
    end
  end

  defp parse_positive_integer(_value, error_reason), do: {:error, error_reason}

  defp parse_boolean(value, _default) when value in [true, "true", "1", 1], do: true
  defp parse_boolean(value, _default) when value in [false, "false", "0", 0], do: false
  defp parse_boolean(_value, default), do: default

  defp unwrap_transaction_result({:ok, payload}), do: {:ok, payload}
  defp unwrap_transaction_result({:error, reason}), do: {:error, reason}
  defp unwrap_or_rollback({:ok, value}), do: value
  defp unwrap_or_rollback({:error, changeset}), do: Repo.rollback(changeset)
end
