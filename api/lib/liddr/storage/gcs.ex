defmodule Liddr.Storage.GCS do
  alias Liddr.Google.ServiceAccount

  @upload_host "storage.googleapis.com"
  @algorithm "GOOG4-RSA-SHA256"
  @service "storage"
  @request_type "goog4_request"
  @max_ttl_seconds 604_800

  def presign_put_upload(object_key, content_type, opts \\ []) do
    ttl_seconds = Keyword.get(opts, :ttl_seconds, 900)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, bucket} <- fetch_env("GCS_BUCKET_VERIFICATION"),
         {:ok, creds} <- ServiceAccount.credentials(),
         {:ok, expires} <- normalize_ttl(ttl_seconds),
         {:ok, canonical} <-
           build_canonical_request(bucket, object_key, content_type, now, expires, creds),
         {:ok, signature_hex} <- sign_string(creds.private_key, canonical.string_to_sign) do
      query = canonical.query <> "&X-Goog-Signature=#{signature_hex}"

      {:ok,
       %{
         upload_url: "https://#{@upload_host}#{canonical.canonical_uri}?#{query}",
         required_headers: %{"content-type" => content_type},
         expires_at: DateTime.add(now, expires, :second) |> DateTime.truncate(:second),
         storage_key: object_key,
         bucket: bucket
       }}
    end
  end

  def presign_get_download(object_key, opts \\ []) do
    ttl_seconds = Keyword.get(opts, :ttl_seconds, 300)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, bucket} <- fetch_env("GCS_BUCKET_VERIFICATION"),
         {:ok, creds} <- ServiceAccount.credentials(),
         {:ok, expires} <- normalize_ttl(ttl_seconds) do
      amz_datetime = format_datetime(now)
      datestamp = format_datestamp(now)
      scope = "#{datestamp}/auto/#{@service}/#{@request_type}"
      signed_headers = "host"
      credential = "#{creds.client_email}/#{scope}"

      canonical_uri =
        "/" <>
          percent_encode_path(bucket) <>
          "/" <> percent_encode_path(String.trim_leading(object_key, "/"))

      query_params = [
        {"X-Goog-Algorithm", @algorithm},
        {"X-Goog-Credential", credential},
        {"X-Goog-Date", amz_datetime},
        {"X-Goog-Expires", Integer.to_string(expires)},
        {"X-Goog-SignedHeaders", signed_headers}
      ]

      canonical_query = encode_query(query_params)
      canonical_headers = "host:#{@upload_host}\n"

      canonical_request =
        """
        GET
        #{canonical_uri}
        #{canonical_query}
        #{canonical_headers}
        #{signed_headers}
        UNSIGNED-PAYLOAD
        """
        |> String.trim_trailing()

      string_to_sign =
        """
        #{@algorithm}
        #{amz_datetime}
        #{scope}
        #{sha256_hex(canonical_request)}
        """
        |> String.trim_trailing()

      with {:ok, signature_hex} <- sign_string(creds.private_key, string_to_sign) do
        query = canonical_query <> "&X-Goog-Signature=#{signature_hex}"

        {:ok,
         %{
           download_url: "https://#{@upload_host}#{canonical_uri}?#{query}",
           expires_at: DateTime.add(now, expires, :second) |> DateTime.truncate(:second),
           storage_key: object_key,
           bucket: bucket
         }}
      end
    end
  end

  defp build_canonical_request(bucket, object_key, content_type, now, expires, creds) do
    amz_datetime = format_datetime(now)
    datestamp = format_datestamp(now)
    scope = "#{datestamp}/auto/#{@service}/#{@request_type}"
    signed_headers = "content-type;host"

    credential = "#{creds.client_email}/#{scope}"

    canonical_uri =
      "/" <>
        percent_encode_path(bucket) <>
        "/" <> percent_encode_path(String.trim_leading(object_key, "/"))

    query_params = [
      {"X-Goog-Algorithm", @algorithm},
      {"X-Goog-Credential", credential},
      {"X-Goog-Date", amz_datetime},
      {"X-Goog-Expires", Integer.to_string(expires)},
      {"X-Goog-SignedHeaders", signed_headers}
    ]

    canonical_query = encode_query(query_params)
    canonical_headers = "content-type:#{String.trim(content_type)}\nhost:#{@upload_host}\n"

    canonical_request =
      """
      PUT
      #{canonical_uri}
      #{canonical_query}
      #{canonical_headers}
      #{signed_headers}
      UNSIGNED-PAYLOAD
      """
      |> String.trim_trailing()

    string_to_sign =
      """
      #{@algorithm}
      #{amz_datetime}
      #{scope}
      #{sha256_hex(canonical_request)}
      """
      |> String.trim_trailing()

    {:ok,
     %{
       canonical_uri: canonical_uri,
       query: canonical_query,
       string_to_sign: string_to_sign
     }}
  end

  defp sign_string(private_key, payload) do
    try do
      signature =
        :public_key.sign(payload, :sha256, private_key)
        |> Base.encode16(case: :lower)

      {:ok, signature}
    rescue
      _ -> {:error, :gcs_signing_failed}
    end
  end

  defp normalize_ttl(ttl_seconds) when is_integer(ttl_seconds) and ttl_seconds > 0 do
    {:ok, min(ttl_seconds, @max_ttl_seconds)}
  end

  defp normalize_ttl(_), do: {:error, :invalid_upload_ttl}

  defp fetch_env(key) do
    case System.get_env(key) do
      nil ->
        {:error, :gcs_bucket_not_configured}

      value ->
        normalized = String.trim(value)
        if normalized == "", do: {:error, :gcs_bucket_not_configured}, else: {:ok, normalized}
    end
  end

  defp encode_query(params) do
    params
    |> Enum.map(fn {k, v} -> {percent_encode(k), percent_encode(v)} end)
    |> Enum.sort()
    |> Enum.map_join("&", fn {k, v} -> "#{k}=#{v}" end)
  end

  defp percent_encode_path(path) do
    URI.encode(path, fn ch -> URI.char_unreserved?(ch) or ch == ?/ end)
  end

  defp percent_encode(value) when is_binary(value) do
    URI.encode(value, &URI.char_unreserved?/1)
  end

  defp percent_encode(value), do: value |> to_string() |> percent_encode()

  defp format_datestamp(datetime), do: Calendar.strftime(datetime, "%Y%m%d")
  defp format_datetime(datetime), do: Calendar.strftime(datetime, "%Y%m%dT%H%M%SZ")

  defp sha256_hex(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end
end
