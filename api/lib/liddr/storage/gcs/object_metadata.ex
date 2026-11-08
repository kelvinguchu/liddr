defmodule Liddr.Storage.GCS.ObjectMetadata do
  alias Liddr.Google.ServiceAccount
  alias Liddr.Storage.GCS

  @scope "https://www.googleapis.com/auth/devstorage.read_only"
  @api_url "https://storage.googleapis.com/storage/v1"
  @connect_timeout 2_000
  @receive_timeout 5_000

  def fetch_object_metadata(object_key) do
    with {:ok, bucket} <- GCS.fetch_verification_bucket(),
         {:ok, object_key} <- GCS.validate_object_key(object_key),
         {:ok, token} <- ServiceAccount.oauth_access_token(@scope),
         {:ok, body} <- request_object_metadata(bucket, object_key, token) do
      parse_object_metadata(body)
    end
  end

  defp request_object_metadata(bucket, object_key, token) do
    url =
      "#{@api_url}/b/#{URI.encode_www_form(bucket)}/o/#{URI.encode_www_form(object_key)}"

    case Req.get(url,
           headers: [{"authorization", "Bearer #{token}"}],
           receive_timeout: @receive_timeout,
           connect_options: [timeout: @connect_timeout],
           retry: false
         ) do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %{status: 404}} -> {:error, :uploaded_file_not_found}
      {:ok, _response} -> {:error, :uploaded_file_unavailable}
      {:error, _reason} -> {:error, :uploaded_file_unavailable}
    end
  end

  defp parse_object_metadata(body) do
    with {:ok, content_type} <- fetch_string(body, "contentType"),
         {:ok, size_bytes} <- fetch_positive_integer(body, "size") do
      {:ok,
       %{
         content_type: String.downcase(content_type),
         file_size_bytes: size_bytes,
         generation: fetch_optional_string(body, "generation"),
         etag: fetch_optional_string(body, "etag"),
         md5_hash: fetch_optional_string(body, "md5Hash"),
         crc32c: fetch_optional_string(body, "crc32c")
       }}
    else
      :error -> {:error, :uploaded_file_unavailable}
    end
  end

  defp fetch_string(body, key) do
    case Map.get(body, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> :error
    end
  end

  defp fetch_positive_integer(body, key) do
    case Map.get(body, key) do
      value when is_integer(value) and value > 0 ->
        {:ok, value}

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > 0 -> {:ok, parsed}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp fetch_optional_string(body, key) do
    case Map.get(body, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end
end
