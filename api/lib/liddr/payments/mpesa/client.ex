defmodule Liddr.Payments.Mpesa.Client do
  @behaviour Liddr.Payments.Mpesa.ClientBehaviour

  alias Liddr.Payments.Mpesa.Client.Config
  alias Liddr.Payments.Mpesa.Client.Error
  alias Liddr.Payments.Mpesa.Client.Normalize
  alias Liddr.Payments.Mpesa.Sanitizer

  @oauth_path "/oauth/v1/generate?grant_type=client_credentials"
  @stk_path "/mpesa/stkpush/v1/processrequest"
  @stk_query_path "/mpesa/stkpushquery/v1/query"
  @tx_status_query_path "/mpesa/transactionstatus/v1/query"

  # `response_payload` stays raw because callers persist its IDs to match Daraja
  # callbacks. Run it through `Sanitizer` before storing or returning the payload.

  @impl true
  def initiate_stk_push(input) when is_map(input) do
    with {:ok, config} <- Config.fetch(),
         {:ok, token} <- fetch_access_token(config),
         {:ok, phone} <- Normalize.phone(Map.get(input, :phone) || Map.get(input, "phone")),
         {:ok, callback_url} <- Normalize.fetch_required(input, :callback_url),
         {:ok, account_reference} <- Normalize.fetch_required(input, :account_reference),
         {:ok, transaction_desc} <- Normalize.fetch_required(input, :transaction_desc),
         {:ok, amount} <- Normalize.amount(Map.get(input, :amount) || Map.get(input, "amount")) do
      timestamp = kenya_timestamp()
      password = Base.encode64("#{config.shortcode}#{config.passkey}#{timestamp}")

      payload = %{
        "BusinessShortCode" => config.shortcode,
        "Password" => password,
        "Timestamp" => timestamp,
        "TransactionType" => config.transaction_type,
        "Amount" => amount,
        "PartyA" => phone,
        "PartyB" => config.shortcode,
        "PhoneNumber" => phone,
        "CallBackURL" => callback_url,
        "AccountReference" => account_reference,
        "TransactionDesc" => transaction_desc
      }

      with {:ok, %{status: status, body: body}} <-
             post_json(:stk_push, config.base_url <> @stk_path, token, payload, config.timeout_ms),
           :ok <- validate_stk_response(status, body) do
        {:ok,
         %{
           request_payload: Sanitizer.payload(payload),
           response_payload: body
         }}
      else
        {:error, _reason} = error -> error
      end
    end
  end

  def initiate_stk_push(_input), do: {:error, :invalid_mpesa_input}

  @impl true
  def query_stk_status(checkout_request_id) when is_binary(checkout_request_id) do
    with {:ok, config} <- Config.fetch(),
         {:ok, token} <- fetch_access_token(config),
         {:ok, normalized_checkout_request_id} <-
           Normalize.checkout_request_id(checkout_request_id) do
      timestamp = kenya_timestamp()
      password = Base.encode64("#{config.shortcode}#{config.passkey}#{timestamp}")

      payload = %{
        "BusinessShortCode" => config.shortcode,
        "Password" => password,
        "Timestamp" => timestamp,
        "CheckoutRequestID" => normalized_checkout_request_id
      }

      with {:ok, %{status: status, body: body}} <-
             post_json(
               :stk_query,
               config.base_url <> @stk_query_path,
               token,
               payload,
               config.timeout_ms
             ),
           :ok <- validate_stk_query_response(status, body) do
        {:ok,
         %{
           request_payload: Sanitizer.payload(payload),
           response_payload: body
         }}
      else
        {:error, _reason} = error -> error
      end
    end
  end

  def query_stk_status(_checkout_request_id), do: {:error, :invalid_checkout_request_id}

  @impl true
  def register_c2b_urls(validation_url, confirmation_url)
      when is_binary(validation_url) and is_binary(confirmation_url) do
    with {:ok, config} <- Config.fetch(),
         {:ok, token} <- fetch_access_token(config),
         {:ok, normalized_validation_url} <- Normalize.url(validation_url, :validation_url),
         {:ok, normalized_confirmation_url} <- Normalize.url(confirmation_url, :confirmation_url) do
      payload = %{
        "ShortCode" => config.shortcode,
        "ResponseType" => "Completed",
        "ValidationURL" => normalized_validation_url,
        "ConfirmationURL" => normalized_confirmation_url,
        "CommandID" => config.c2b_command_id
      }

      case post_json(
             :c2b_register,
             config.base_url <> config.c2b_register_path,
             token,
             payload,
             config.timeout_ms
           ) do
        {:ok, %{status: status, body: body}} ->
          with :ok <- validate_c2b_register_response(status, body) do
            {:ok,
             %{
               request_payload: Sanitizer.payload(payload),
               response_payload: body
             }}
          end

        {:error, _reason} = error ->
          error
      end
    end
  end

  def register_c2b_urls(_validation_url, _confirmation_url), do: {:error, :invalid_mpesa_input}

  @impl true
  def query_transaction_status(input) when is_map(input) do
    with {:ok, config} <- Config.fetch(),
         {:ok, initiator_name} <-
           Config.required_value(config.initiator_name, "MPESA_INITIATOR_NAME"),
         {:ok, security_credential} <-
           Config.required_value(config.security_credential, "MPESA_SECURITY_CREDENTIAL"),
         {:ok, token} <- fetch_access_token(config),
         {:ok, transaction_id} <- Normalize.fetch_required(input, :transaction_id),
         {:ok, result_url} <- Normalize.fetch_required(input, :result_url),
         {:ok, timeout_url} <- Normalize.fetch_required(input, :timeout_url),
         {:ok, normalized_result_url} <- Normalize.url(result_url, :result_url),
         {:ok, normalized_timeout_url} <- Normalize.url(timeout_url, :timeout_url) do
      payload = %{
        "Initiator" => initiator_name,
        "SecurityCredential" => security_credential,
        "CommandID" => config.tx_status_command_id,
        "TransactionID" => transaction_id,
        "PartyA" => config.shortcode,
        "IdentifierType" => config.identifier_type,
        "ResultURL" => normalized_result_url,
        "QueueTimeOutURL" => normalized_timeout_url,
        "Remarks" =>
          Normalize.optional_text(
            Map.get(input, :remarks) || Map.get(input, "remarks"),
            "Status reconciliation"
          ),
        "Occasion" =>
          Normalize.optional_text(
            Map.get(input, :occasion) || Map.get(input, "occasion"),
            "SubscriptionStatusCheck"
          )
      }

      with {:ok, %{status: status, body: body}} <-
             post_json(
               :transaction_status_query,
               config.base_url <> @tx_status_query_path,
               token,
               payload,
               config.timeout_ms
             ),
           :ok <- validate_tx_status_response(status, body) do
        {:ok,
         %{
           request_payload: Sanitizer.payload(payload),
           response_payload: body
         }}
      else
        {:error, _reason} = error -> error
      end
    end
  end

  def query_transaction_status(_input), do: {:error, :invalid_mpesa_input}

  defp fetch_access_token(config) do
    auth = Base.encode64("#{config.consumer_key}:#{config.consumer_secret}")

    case Req.get(config.base_url <> @oauth_path,
           headers: [{"authorization", "Basic " <> auth}],
           receive_timeout: config.timeout_ms
         ) do
      {:ok, %{status: 200, body: %{"access_token" => token}}}
      when is_binary(token) and token != "" ->
        {:ok, token}

      {:ok, %{status: 200, body: body}} ->
        {:error, Error.invalid_response(:oauth_token, 200, body)}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.http(:oauth_token, status, body)}

      {:error, reason} ->
        {:error, Error.transport(:oauth_token, reason)}
    end
  end

  defp post_json(operation, url, token, payload, timeout_ms) do
    case Req.post(url, auth: {:bearer, token}, json: payload, receive_timeout: timeout_ms) do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, Error.transport(operation, reason)}
    end
  end

  defp validate_stk_response(status, body) when status in 200..299 and is_map(body) do
    with {:ok, _code} <- required_string(body, "ResponseCode", :stk_push, status),
         {:ok, _merchant_request_id} <-
           required_string(body, "MerchantRequestID", :stk_push, status),
         {:ok, _checkout_request_id} <-
           required_string(body, "CheckoutRequestID", :stk_push, status) do
      :ok
    end
  end

  defp validate_stk_response(status, body), do: {:error, Error.http(:stk_push, status, body)}

  defp validate_stk_query_response(status, body) when status in 200..299 and is_map(body) do
    with {:ok, _result_code} <- required_string(body, "ResultCode", :stk_query, status),
         {:ok, _result_desc} <- required_string(body, "ResultDesc", :stk_query, status) do
      :ok
    end
  end

  defp validate_stk_query_response(status, body),
    do: {:error, Error.http(:stk_query, status, body)}

  defp validate_c2b_register_response(status, body) when status in 200..299 and is_map(body) do
    required_string(body, "ResponseDescription", :c2b_register, status)
    |> case do
      {:ok, _value} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp validate_c2b_register_response(status, body),
    do: {:error, Error.http(:c2b_register, status, body)}

  defp validate_tx_status_response(status, body) when status in 200..299 and is_map(body) do
    with {:ok, _response_code} <-
           required_string(body, "ResponseCode", :transaction_status_query, status),
         {:ok, _response_desc} <-
           required_string(body, "ResponseDescription", :transaction_status_query, status),
         {:ok, _conversation_id} <-
           required_string(body, "ConversationID", :transaction_status_query, status),
         {:ok, _originator_conversation_id} <-
           required_string(body, "OriginatorConversationID", :transaction_status_query, status) do
      :ok
    end
  end

  defp validate_tx_status_response(status, body),
    do: {:error, Error.http(:transaction_status_query, status, body)}

  defp required_string(body, key, operation, status) do
    case Normalize.text(Map.get(body, key)) do
      nil -> {:error, Error.invalid_response(operation, status, body)}
      value -> {:ok, value}
    end
  end

  # Kenya is UTC+3 year-round.
  defp kenya_timestamp do
    DateTime.utc_now()
    |> DateTime.add(3 * 60 * 60, :second)
    |> Calendar.strftime("%Y%m%d%H%M%S")
  end
end
