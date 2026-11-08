defmodule LiddrWeb.Idempotency do
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Liddr.Idempotency

  def execute(conn, operation, payload, execute_fun, render_error_fun)
      when is_function(execute_fun, 0) and is_function(render_error_fun, 2) do
    user_id = conn.assigns.current_user.id
    idempotency_key = request_header(conn, "idempotency-key")

    case Idempotency.claim(user_id, operation, idempotency_key, payload) do
      :bypass ->
        run_without_idempotency(conn, execute_fun, render_error_fun)

      {:proceed, claim} ->
        run_with_claim(conn, claim, execute_fun, render_error_fun)

      {:replay, %{status: status, body: body}} ->
        conn
        |> put_status(status)
        |> json(body)

      {:error, :idempotency_payload_mismatch} ->
        error(conn, :conflict, "IDEMPOTENCY_KEY_REUSED", "Idempotency key payload mismatch")

      {:error, :idempotency_in_progress} ->
        error(
          conn,
          :conflict,
          "IDEMPOTENCY_REQUEST_IN_PROGRESS",
          "An identical request is still in progress"
        )

      {:error, :invalid_idempotency_key} ->
        error(
          conn,
          :unprocessable_entity,
          "INVALID_IDEMPOTENCY_KEY",
          "idempotency-key header must be 8-120 characters"
        )

      {:error, :invalid_idempotency_operation} ->
        error(
          conn,
          :unprocessable_entity,
          "INVALID_IDEMPOTENCY_OPERATION",
          "Idempotency operation is invalid"
        )

      {:error, _reason} ->
        error(
          conn,
          :unprocessable_entity,
          "IDEMPOTENCY_ERROR",
          "Unable to process idempotency key"
        )
    end
  end

  defp run_without_idempotency(conn, execute_fun, render_error_fun) do
    case execute_fun.() do
      {:ok, status, body} ->
        conn
        |> put_status(status)
        |> json(body)

      {:error, reason} ->
        render_error_fun.(conn, reason)
    end
  end

  defp run_with_claim(conn, claim, execute_fun, render_error_fun) do
    case execute_claimed(claim, execute_fun) do
      {:ok, status, body} ->
        _ = Idempotency.complete(claim, status, body)

        conn
        |> put_status(status)
        |> json(body)

      {:error, reason} ->
        _ = Idempotency.abandon(claim)
        render_error_fun.(conn, reason)
    end
  end

  defp execute_claimed(claim, execute_fun) do
    execute_fun.()
  catch
    kind, reason ->
      _ = Idempotency.abandon(claim)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp request_header(conn, name) do
    case get_req_header(conn, name) do
      [value | _] -> value
      _ -> nil
    end
  end

  defp error(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end
