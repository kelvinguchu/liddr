defmodule LiddrWeb.RatingController do
  use LiddrWeb, :controller

  alias Liddr.Ratings

  @known_errors %{
    ride_not_found: {:not_found, "RIDE_NOT_FOUND", "Ride was not found"},
    ride_not_accessible:
      {:forbidden, "RIDE_NOT_ACCESSIBLE", "Ride is not accessible for this user"},
    ride_not_rateable:
      {:unprocessable_entity, "RIDE_NOT_RATEABLE", "Ride can only be rated after completion"},
    rating_action_not_pending:
      {:unprocessable_entity, "RATING_NOT_PENDING", "No pending rating action for this ride"},
    invalid_rating_score:
      {:unprocessable_entity, "INVALID_RATING_SCORE", "score must be an integer between 1 and 5"},
    missing_rating_reasons:
      {:unprocessable_entity, "MISSING_RATING_REASONS",
       "reason_tags is required when score is below 5"},
    rated_user_not_found: {:not_found, "RATED_USER_NOT_FOUND", "Rated user not found"}
  }

  def pending(conn, _params) do
    user_id = conn.assigns.current_user.id
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    actions =
      Ratings.list_pending_for_user(user_id, now)
      |> Enum.map(&pending_payload/1)

    json(conn, %{data: %{pending_ratings: actions}})
  end

  def rate(conn, %{"ride_id" => ride_id}) do
    user_id = conn.assigns.current_user.id

    case Ratings.rate_ride(user_id, ride_id, conn.body_params) do
      {:ok, payload} ->
        conn
        |> put_status(:created)
        |> json(%{data: rating_payload(payload)})

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  def skip(conn, %{"ride_id" => ride_id}) do
    user_id = conn.assigns.current_user.id

    case Ratings.skip_ride_rating(user_id, ride_id) do
      {:ok, payload} ->
        json(conn, %{data: payload})

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  defp rating_payload(payload) do
    %{
      rating: %{
        id: payload.rating.id,
        ride_id: payload.rating.ride_id,
        rated_by_user_id: payload.rating.rated_by_user_id,
        rated_user_id: payload.rating.rated_user_id,
        score: payload.rating.score,
        reason_tags: payload.rating.reason_tags,
        include_in_score: payload.rating.include_in_score,
        exclusion_reason_code: payload.rating.exclusion_reason_code,
        submitted_at: payload.rating.submitted_at
      },
      rating_action_status: payload.rating_action_status,
      rated_user_stats: %{
        rating_score: payload.rated_user_stats.rating_score,
        rating_count: payload.rated_user_stats.rating_count
      }
    }
  end

  defp pending_payload(action) do
    %{
      action_id: action.action_id,
      ride_id: action.ride_id,
      rated_user_id: action.rated_user_id,
      rater_role: action.rater_role,
      due_at: action.due_at,
      completed_at: action.completed_at
    }
  end

  defp render_error(conn, reason) when is_atom(reason) do
    case Map.get(@known_errors, reason) do
      {status, code, message} ->
        conn
        |> put_status(status)
        |> json(%{error: %{code: code, message: message}})

      nil ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "RATING_ERROR", message: "Unable to process rating action"}})
    end
  end

  defp render_error(conn, _reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "RATING_ERROR", message: "Unable to process rating action"}})
  end
end
