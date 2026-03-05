defmodule LiddrWeb.ModerationErrors do
  alias Ecto.Changeset
  import Plug.Conn, only: [put_status: 2]
  import Phoenix.Controller, only: [json: 2]

  def render(conn, :user_not_found),
    do: error_response(conn, :not_found, "USER_NOT_FOUND", "User not found")

  def render(conn, :report_not_found),
    do: error_response(conn, :not_found, "REPORT_NOT_FOUND", "Report not found")

  def render(conn, :invalid_triage_status),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "INVALID_TRIAGE_STATUS",
        "Triage status must be triaged or under_review"
      )

  def render(conn, :invalid_review_decision),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "INVALID_REVIEW_DECISION",
        "Unsupported moderation review decision"
      )

  def render(conn, :report_not_triageable),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "REPORT_NOT_TRIAGEABLE",
        "Report cannot be triaged in its current state"
      )

  def render(conn, :report_not_reviewable),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "REPORT_NOT_REVIEWABLE",
        "Report cannot be reviewed in its current state"
      )

  def render(conn, :missing_enforcement_ends_at),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "MISSING_ENFORCEMENT_ENDS_AT",
        "Temporary suspension review requires a future ends_at timestamp"
      )

  def render(conn, :invalid_enforcement_ends_at),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "INVALID_ENFORCEMENT_ENDS_AT",
        "ends_at must be a valid future ISO8601 datetime"
      )

  def render(conn, :invalid_reconciliation_limit),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "INVALID_RECONCILIATION_LIMIT",
        "limit must be an integer between 1 and 1000"
      )

  def render(conn, :invalid_due_within_hours),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "INVALID_DUE_WITHIN_HOURS",
        "due_within_hours must be an integer between 1 and 720"
      )

  def render(conn, %Changeset{} = changeset) do
    details = Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)

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

  def render(conn, _unknown),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "ENFORCEMENT_ERROR",
        "Unable to apply enforcement"
      )

  def parse_reconciliation_limit(params) do
    value = Map.get(params, "limit") || Map.get(params, :limit)

    case value do
      nil ->
        {:ok, 200}

      parsed when is_integer(parsed) and parsed >= 1 and parsed <= 1000 ->
        {:ok, parsed}

      binary when is_binary(binary) ->
        case Integer.parse(String.trim(binary)) do
          {parsed, ""} when parsed >= 1 and parsed <= 1000 -> {:ok, parsed}
          _ -> {:error, :invalid_reconciliation_limit}
        end

      _ ->
        {:error, :invalid_reconciliation_limit}
    end
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end
