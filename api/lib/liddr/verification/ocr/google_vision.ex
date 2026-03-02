defmodule Liddr.Verification.OCR.GoogleVision do
  alias Liddr.Google.ServiceAccount
  alias Liddr.Verification.OCR.GoogleVision.Config
  alias Liddr.Verification.OCR.GoogleVision.Parser

  @vision_scope "https://www.googleapis.com/auth/cloud-platform"
  @vision_base_url "https://vision.googleapis.com/v1"
  @vision_annotate_url "#{@vision_base_url}/images:annotate"
  @vision_async_url "#{@vision_base_url}/files:asyncBatchAnnotate"
  @gcs_api_url "https://storage.googleapis.com/storage/v1"

  def extract_storage_key(storage_key, opts \\ [])

  def extract_storage_key(storage_key, opts) when is_binary(storage_key) do
    file_mime = opts |> Keyword.get(:file_mime) |> Config.normalize_text()
    document_type = opts |> Keyword.get(:document_type) |> Config.normalize_text()

    with {:ok, bucket} <- Config.fetch_verification_bucket(),
         {:ok, token} <- ServiceAccount.oauth_access_token(@vision_scope),
         {:ok, text, meta} <- extract_text(token, bucket, storage_key, file_mime) do
      {:ok, Parser.build_result(text, file_mime, document_type, bucket, storage_key, meta)}
    end
  end

  def extract_storage_key(_storage_key, _opts), do: {:error, :ocr_invalid_storage_key}

  defp extract_text(token, bucket, storage_key, "application/pdf") do
    with {:ok, output_bucket} <- Config.fetch_ocr_output_bucket(bucket),
         {:ok, output_prefix} <- Config.build_ocr_output_prefix(storage_key),
         {:ok, operation_name} <-
           start_pdf_operation(token, bucket, storage_key, output_bucket, output_prefix),
         {:ok, operation_response} <- wait_for_operation(token, operation_name),
         {:ok, resolved_location} <-
           resolve_output_location(operation_response, output_bucket, output_prefix),
         {:ok, text, page_count, file_count} <-
           fetch_pdf_output_text(token, resolved_location.bucket, resolved_location.prefix) do
      {:ok, text,
       %{
         mode: "async_pdf",
         page_count: page_count,
         output_file_count: file_count,
         output_bucket: resolved_location.bucket,
         output_prefix: resolved_location.prefix
       }}
    end
  end

  defp extract_text(token, bucket, storage_key, _file_mime) do
    with {:ok, response} <- annotate_image(token, bucket, storage_key),
         {:ok, text} <- Parser.parse_image_text(response) do
      {:ok, text, %{mode: "image"}}
    end
  end

  defp annotate_image(token, bucket, storage_key) do
    payload = %{
      "requests" => [
        %{
          "image" => %{"source" => %{"gcsImageUri" => "gs://#{bucket}/#{storage_key}"}},
          "features" => [%{"type" => "DOCUMENT_TEXT_DETECTION"}]
        }
      ]
    }

    case Req.post(@vision_annotate_url,
           auth: {:bearer, token},
           json: payload,
           receive_timeout: Config.timeout_ms()
         ) do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, _response} -> {:error, :ocr_provider_failed}
      {:error, _reason} -> {:error, :ocr_provider_failed}
    end
  end

  defp start_pdf_operation(token, bucket, storage_key, output_bucket, output_prefix) do
    payload = %{
      "requests" => [
        %{
          "inputConfig" => %{
            "gcsSource" => %{"uri" => "gs://#{bucket}/#{storage_key}"},
            "mimeType" => "application/pdf"
          },
          "features" => [%{"type" => "DOCUMENT_TEXT_DETECTION"}],
          "outputConfig" => %{
            "gcsDestination" => %{"uri" => "gs://#{output_bucket}/#{output_prefix}"},
            "batchSize" => Config.pdf_batch_size()
          }
        }
      ]
    }

    case Req.post(@vision_async_url,
           auth: {:bearer, token},
           json: payload,
           receive_timeout: Config.timeout_ms()
         ) do
      {:ok, %{status: 200, body: %{"name" => name}}} when is_binary(name) and name != "" ->
        {:ok, name}

      {:ok, _response} ->
        {:error, :ocr_provider_failed}

      {:error, _reason} ->
        {:error, :ocr_provider_failed}
    end
  end

  defp wait_for_operation(token, operation_name) do
    deadline_ms = System.monotonic_time(:millisecond) + Config.pdf_poll_timeout_ms()
    wait_for_operation(token, operation_name, deadline_ms)
  end

  defp wait_for_operation(token, operation_name, deadline_ms) do
    operation_url = "#{@vision_base_url}/#{operation_name}"

    case Req.get(operation_url, auth: {:bearer, token}, receive_timeout: Config.timeout_ms()) do
      {:ok, %{status: 200, body: %{"done" => true, "error" => _error}}} ->
        {:error, :ocr_provider_failed}

      {:ok, %{status: 200, body: %{"done" => true} = body}} ->
        {:ok, body}

      {:ok, %{status: 200, body: %{"done" => false}}} ->
        if System.monotonic_time(:millisecond) >= deadline_ms do
          {:error, :ocr_provider_timeout}
        else
          Process.sleep(Config.pdf_poll_interval_ms())
          wait_for_operation(token, operation_name, deadline_ms)
        end

      {:ok, _response} ->
        {:error, :ocr_provider_failed}

      {:error, _reason} ->
        {:error, :ocr_provider_failed}
    end
  end

  defp resolve_output_location(operation_response, fallback_bucket, fallback_prefix) do
    uri =
      get_in(operation_response, ["response", "responses"])
      |> case do
        [first | _] when is_map(first) ->
          get_in(first, ["outputConfig", "gcsDestination", "uri"])

        _ ->
          nil
      end

    case Config.parse_gcs_uri(uri) do
      {:ok, %{bucket: bucket, prefix: prefix}} -> {:ok, %{bucket: bucket, prefix: prefix}}
      _ -> {:ok, %{bucket: fallback_bucket, prefix: fallback_prefix}}
    end
  end

  defp fetch_pdf_output_text(token, bucket, prefix) do
    with {:ok, object_names} <- list_output_json_objects(token, bucket, prefix),
         {:ok, texts, page_count} <- read_output_json_objects(token, bucket, object_names) do
      combined_text =
        texts
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n")

      {:ok, combined_text, page_count, length(object_names)}
    end
  end

  defp list_output_json_objects(token, bucket, prefix) do
    encoded_prefix = URI.encode_www_form(prefix)
    url = "#{@gcs_api_url}/b/#{URI.encode_www_form(bucket)}/o?prefix=#{encoded_prefix}"

    case Req.get(url, auth: {:bearer, token}, receive_timeout: Config.timeout_ms()) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        items = Map.get(body, "items", [])

        names =
          items
          |> Enum.map(&Map.get(&1, "name"))
          |> Enum.filter(&is_binary/1)
          |> Enum.filter(&String.ends_with?(&1, ".json"))
          |> Enum.sort()

        if names == [], do: {:error, :ocr_output_missing}, else: {:ok, names}

      {:ok, _response} ->
        {:error, :ocr_provider_failed}

      {:error, _reason} ->
        {:error, :ocr_provider_failed}
    end
  end

  defp read_output_json_objects(token, bucket, object_names) do
    Enum.reduce_while(object_names, {:ok, [], 0}, fn object_name, {:ok, texts, pages} ->
      case read_output_object(token, bucket, object_name) do
        {:ok, text, page_count} ->
          {:cont, {:ok, [text | texts], pages + page_count}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, texts, pages} -> {:ok, Enum.reverse(texts), pages}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_output_object(token, bucket, object_name) do
    encoded_name = URI.encode_www_form(object_name)
    url = "#{@gcs_api_url}/b/#{URI.encode_www_form(bucket)}/o/#{encoded_name}?alt=media"

    case Req.get(url, auth: {:bearer, token}, receive_timeout: Config.timeout_ms()) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        Parser.parse_output_file(body)

      {:ok, _response} ->
        {:error, :ocr_provider_failed}

      {:error, _reason} ->
        {:error, :ocr_provider_failed}
    end
  end
end
