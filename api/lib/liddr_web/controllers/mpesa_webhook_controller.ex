defmodule LiddrWeb.MpesaWebhookController do
  use LiddrWeb, :controller

  require Logger

  alias Liddr.Subscriptions

  def stk_callback(conn, params) do
    with :ok <- verify_callback_token(conn, params),
         {:ok, _result} <- Subscriptions.handle_stk_callback(params) do
      json(conn, %{"ResultCode" => 0, "ResultDesc" => "Accepted"})
    else
      {:error, :subscription_payment_not_found} ->
        Logger.warning("[mpesa.stk_callback] unmatched callback accepted for reconciliation")

        json(conn, %{"ResultCode" => 0, "ResultDesc" => "Accepted"})

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  def c2b_validation(conn, params) do
    with :ok <- verify_callback_token(conn, params) do
      json(conn, %{"ResultCode" => 0, "ResultDesc" => "Accepted"})
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def c2b_confirmation(conn, params) do
    with :ok <- verify_callback_token(conn, params),
         {:ok, _result} <- Subscriptions.handle_c2b_callback(params) do
      json(conn, %{"ResultCode" => 0, "ResultDesc" => "Accepted"})
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def tx_status_callback(conn, params) do
    with :ok <- verify_callback_token(conn, params),
         {:ok, _result} <- Subscriptions.handle_transaction_status_callback(params) do
      json(conn, %{"ResultCode" => 0, "ResultDesc" => "Accepted"})
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  defp verify_callback_token(conn, params) do
    token = resolve_callback_token(conn, params)
    Subscriptions.verify_callback_token(token)
  end

  defp resolve_callback_token(conn, params) do
    header_token =
      List.first(get_req_header(conn, "x-mpesa-callback-token")) ||
        List.first(get_req_header(conn, "x-callback-token"))

    query_token = Map.get(params, "token")

    case Subscriptions.callback_token_transport() do
      "header" -> header_token
      "query" -> query_token
      _ -> header_token || query_token
    end
  end

  defp render_error(conn, :invalid_callback_token) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: %{code: "INVALID_CALLBACK_TOKEN", message: "Invalid callback token"}})
  end

  defp render_error(conn, :invalid_stk_callback_payload) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        code: "INVALID_STK_CALLBACK_PAYLOAD",
        message: "Invalid M-Pesa callback payload"
      }
    })
  end

  defp render_error(conn, :invalid_c2b_callback_payload) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        code: "INVALID_C2B_CALLBACK_PAYLOAD",
        message: "Invalid M-Pesa C2B callback payload"
      }
    })
  end

  defp render_error(conn, :invalid_transaction_status_callback_payload) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        code: "INVALID_TX_STATUS_CALLBACK_PAYLOAD",
        message: "Invalid M-Pesa transaction status callback payload"
      }
    })
  end

  defp render_error(conn, :subscription_payment_not_found) do
    conn
    |> put_status(:not_found)
    |> json(%{
      error: %{
        code: "SUBSCRIPTION_PAYMENT_NOT_FOUND",
        message: "Subscription payment not found for callback reference"
      }
    })
  end

  defp render_error(conn, :subscription_not_found) do
    conn
    |> put_status(:not_found)
    |> json(%{
      error: %{
        code: "SUBSCRIPTION_NOT_FOUND",
        message: "Subscription not found for callback reference"
      }
    })
  end

  defp render_error(conn, :invalid_c2b_bill_ref) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        code: "INVALID_C2B_BILL_REF",
        message: "C2B callback BillRefNumber is invalid"
      }
    })
  end

  defp render_error(conn, :callback_amount_mismatch) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        code: "CALLBACK_AMOUNT_MISMATCH",
        message: "Callback amount does not match the pending subscription payment"
      }
    })
  end

  defp render_error(conn, :callback_phone_mismatch) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        code: "CALLBACK_PHONE_MISMATCH",
        message: "Callback phone does not match the pending subscription payment"
      }
    })
  end

  defp render_error(conn, _reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "MPESA_CALLBACK_ERROR", message: "Unable to process callback"}})
  end
end
