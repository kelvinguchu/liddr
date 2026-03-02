defmodule Liddr.Payments.Mpesa.ClientBehaviour do
  @callback initiate_stk_push(map()) ::
              {:ok, %{request_payload: map(), response_payload: map()}} | {:error, term()}

  @callback query_stk_status(binary()) ::
              {:ok, %{request_payload: map(), response_payload: map()}} | {:error, term()}

  @callback register_c2b_urls(binary(), binary()) ::
              {:ok, %{request_payload: map(), response_payload: map()}} | {:error, term()}

  @callback query_transaction_status(map()) ::
              {:ok, %{request_payload: map(), response_payload: map()}} | {:error, term()}
end
