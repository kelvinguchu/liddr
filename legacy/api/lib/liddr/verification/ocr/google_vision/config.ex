defmodule Liddr.Verification.OCR.GoogleVision.Config do
  @default_timeout_ms 20_000
  @default_pdf_poll_timeout_ms 120_000
  @default_pdf_poll_interval_ms 1_000
  @default_pdf_batch_size 5
  @default_ocr_output_prefix "verification/ocr-output"

  def fetch_verification_bucket do
    case System.get_env("GCS_BUCKET_VERIFICATION") do
      nil ->
        {:error, :gcs_bucket_not_configured}

      value ->
        normalized = String.trim(value)
        if normalized == "", do: {:error, :gcs_bucket_not_configured}, else: {:ok, normalized}
    end
  end

  def fetch_ocr_output_bucket(default_bucket) do
    case System.get_env("GCS_BUCKET_OCR_OUTPUT") do
      nil ->
        {:ok, default_bucket}

      value ->
        trimmed = String.trim(value)
        if trimmed == "", do: {:ok, default_bucket}, else: {:ok, trimmed}
    end
  end

  def build_ocr_output_prefix(storage_key) do
    base_prefix =
      case System.get_env("GCS_OCR_OUTPUT_PREFIX") do
        nil -> @default_ocr_output_prefix
        value -> String.trim(value)
      end
      |> case do
        "" -> @default_ocr_output_prefix
        value -> String.trim(value, "/")
      end

    unique_id = "#{System.system_time(:millisecond)}_#{System.unique_integer([:positive])}"
    sanitized_key = storage_key |> String.trim("/") |> String.replace("/", "_")
    {:ok, "#{base_prefix}/#{sanitized_key}/#{unique_id}/"}
  end

  def parse_gcs_uri(nil), do: :error

  def parse_gcs_uri(uri) when is_binary(uri) do
    normalized = String.trim(uri)

    if String.starts_with?(normalized, "gs://") do
      without_scheme = String.replace_prefix(normalized, "gs://", "")

      case String.split(without_scheme, "/", parts: 2) do
        [bucket] when bucket != "" ->
          {:ok, %{bucket: bucket, prefix: ""}}

        [bucket, prefix] when bucket != "" ->
          {:ok, %{bucket: bucket, prefix: prefix}}

        _ ->
          :error
      end
    else
      :error
    end
  end

  def parse_gcs_uri(_), do: :error

  def timeout_ms do
    parse_positive_integer_env("GOOGLE_VISION_TIMEOUT_MS", @default_timeout_ms)
  end

  def pdf_poll_timeout_ms do
    parse_positive_integer_env("GOOGLE_VISION_PDF_POLL_TIMEOUT_MS", @default_pdf_poll_timeout_ms)
  end

  def pdf_poll_interval_ms do
    parse_positive_integer_env(
      "GOOGLE_VISION_PDF_POLL_INTERVAL_MS",
      @default_pdf_poll_interval_ms
    )
  end

  def pdf_batch_size do
    parse_positive_integer_env("GOOGLE_VISION_PDF_BATCH_SIZE", @default_pdf_batch_size)
  end

  def normalize_text(nil), do: nil

  def normalize_text(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      text -> text
    end
  end

  def normalize_text(value), do: value |> to_string() |> normalize_text()

  defp parse_positive_integer_env(key, default) do
    case System.get_env(key) do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> default
        end
    end
  end
end
