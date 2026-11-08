defmodule Liddr.TestSupport.MpesaStubPlug do
  @moduledoc false

  import Plug.Conn

  def checkout_request_id, do: "ws_CO_08112026120000000712345678"
  def merchant_request_id, do: "29115-34620561-1"

  def init(opts), do: opts

  def call(%{request_path: "/oauth/v1/generate"} = conn, _opts) do
    respond(conn, %{"access_token" => "stub-access-token"})
  end

  def call(%{request_path: "/mpesa/stkpush/v1/processrequest"} = conn, _opts) do
    respond(conn, %{
      "ResponseCode" => "0",
      "ResponseDescription" => "Success. Request accepted for processing",
      "MerchantRequestID" => merchant_request_id(),
      "CheckoutRequestID" => checkout_request_id()
    })
  end

  def call(%{request_path: "/mpesa/stkpushquery/v1/query"} = conn, _opts) do
    respond(conn, %{
      "ResultCode" => "0",
      "ResultDesc" => "The service request is processed successfully.",
      "MerchantRequestID" => merchant_request_id(),
      "CheckoutRequestID" => checkout_request_id()
    })
  end

  def call(conn, _opts), do: send_resp(conn, 404, "")

  defp respond(conn, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(body))
  end
end
