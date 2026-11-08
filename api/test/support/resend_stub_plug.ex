defmodule Liddr.TestSupport.ResendStubPlug do
  @moduledoc false

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, opts) do
    {:ok, body, conn} = read_body(conn)
    authorization = get_req_header(conn, "authorization")

    send(
      opts[:test_pid],
      {:resend_request, conn.request_path, authorization, Jason.decode!(body)}
    )

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(opts[:status], Jason.encode!(opts[:body]))
  end
end
