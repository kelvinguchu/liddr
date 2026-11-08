defmodule LiddrWeb.RatingOpsController do
  use LiddrWeb, :controller

  alias Liddr.Ratings
  alias LiddrWeb.Idempotency

  def index(conn, params) do
    with {:ok, ratings} <- Ratings.list_ratings(params) do
      json(conn, %{data: %{ratings: Enum.map(ratings, &rating_payload/1)}})
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def excluded(conn, params) do
    with {:ok, ratings} <- Ratings.list_excluded_ratings(params) do
      json(conn, %{data: %{ratings: Enum.map(ratings, &rating_payload/1)}})
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def nullify(conn, %{"id" => rating_id} = params) do
    actor_user_id = conn.assigns.current_user.id

    Idempotency.execute(
      conn,
      "ops.rating.nullify:#{rating_id}",
      params,
      fn ->
        case Ratings.nullify_rating(rating_id, params, actor_user_id) do
          {:ok, payload} -> {:ok, 200, %{data: ops_mutation_payload(payload)}}
          {:error, reason} -> {:error, reason}
        end
      end,
      &render_error/2
    )
  end

  def reinstate(conn, %{"id" => rating_id} = params) do
    actor_user_id = conn.assigns.current_user.id

    Idempotency.execute(
      conn,
      "ops.rating.reinstate:#{rating_id}",
      params,
      fn ->
        case Ratings.reinstate_rating(rating_id, params, actor_user_id) do
          {:ok, payload} -> {:ok, 200, %{data: ops_mutation_payload(payload)}}
          {:error, reason} -> {:error, reason}
        end
      end,
      &render_error/2
    )
  end

  def guardrails(conn, %{"rated_user_id" => rated_user_id}) do
    with {:ok, parsed_user_id} <- parse_positive_integer(rated_user_id),
         snapshot <- Ratings.enforcement_snapshot_for_user(parsed_user_id, now()) do
      json(conn, %{data: %{guardrails: snapshot}})
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  defp ops_mutation_payload(payload) do
    %{
      rating: rating_payload(payload.rating),
      rated_user_stats: %{
        rating_score: payload.rated_user_stats.rating_score,
        rating_count: payload.rated_user_stats.rating_count
      },
      guardrails: payload.guardrails
    }
  end

  defp rating_payload(rating) do
    %{
      id: rating.id,
      ride_id: rating.ride_id,
      rated_by_user_id: rating.rated_by_user_id,
      rated_user_id: rating.rated_user_id,
      score: rating.score,
      reason_tags: rating.reason_tags,
      comment: rating.comment,
      include_in_score: rating.include_in_score,
      exclusion_reason_code: rating.exclusion_reason_code,
      nullified_at: rating.nullified_at,
      nullified_by_user_id: rating.nullified_by_user_id,
      nullification_reason_code: rating.nullification_reason_code,
      nullification_note: rating.nullification_note,
      submitted_at: rating.submitted_at
    }
  end

  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> {:error, :invalid_rated_user_id}
    end
  end

  defp parse_positive_integer(_value), do: {:error, :invalid_rated_user_id}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp render_error(conn, :rating_not_found),
    do: error_response(conn, :not_found, "RATING_NOT_FOUND", "Rating not found")

  defp render_error(conn, :rating_already_nullified),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "RATING_ALREADY_NULLIFIED",
        "Rating is already nullified"
      )

  defp render_error(conn, :rating_not_nullified),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "RATING_NOT_NULLIFIED",
        "Rating is not nullified"
      )

  defp render_error(conn, :invalid_rating_id),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "INVALID_RATING_ID",
        "rating id must be a positive integer"
      )

  defp render_error(conn, :invalid_rated_user_id),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "INVALID_RATED_USER_ID",
        "rated_user_id must be a positive integer"
      )

  defp render_error(conn, :missing_reason_code),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "MISSING_REASON_CODE",
        "reason_code is required"
      )

  defp render_error(conn, %Ecto.Changeset{} = changeset) do
    details = Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        code: "VALIDATION_ERROR",
        message: "Validation failed",
        details: details
      }
    })
  end

  defp render_error(conn, _reason),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "RATING_OPS_ERROR",
        "Unable to process rating operation"
      )

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end
