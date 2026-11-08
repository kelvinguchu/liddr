defmodule LiddrWeb.Plugs.RequireStepUpAuth do
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Liddr.Auth.StepUp

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, token} <- fetch_step_up_token(conn),
         {:ok, current_user} <- Map.fetch(conn.assigns, :current_user),
         {:ok, current_session_id} <- Map.fetch(conn.assigns, :current_session_id),
         :ok <- StepUp.verify_token(token, current_user.id, current_session_id) do
      conn
    else
      {:error, reason} ->
        render_error(conn, reason)

      :error ->
        render_error(conn, :step_up_required)
    end
  end

  defp fetch_step_up_token(conn) do
    case get_req_header(conn, "x-step-up-token") do
      [token | _] when is_binary(token) ->
        case String.trim(token) do
          "" -> {:error, :step_up_required}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :step_up_required}
    end
  end

  defp render_error(conn, :step_up_required) do
    conn
    |> put_status(:forbidden)
    |> json(%{
      error: %{
        code: "STEP_UP_REQUIRED",
        message: "A valid step-up token is required for this action"
      }
    })
    |> halt()
  end

  defp render_error(conn, :step_up_token_expired) do
    conn
    |> put_status(:forbidden)
    |> json(%{
      error: %{
        code: "STEP_UP_TOKEN_EXPIRED",
        message: "The step-up token has expired"
      }
    })
    |> halt()
  end

  defp render_error(conn, _reason) do
    conn
    |> put_status(:forbidden)
    |> json(%{
      error: %{
        code: "INVALID_STEP_UP_TOKEN",
        message: "Invalid step-up token"
      }
    })
    |> halt()
  end
end
