defmodule Liddr.Verification.OCR.GoogleVision.Parser do
  def parse_output_file(%{"responses" => responses}) when is_list(responses) do
    {texts, page_count, has_error} =
      Enum.reduce(responses, {[], 0, false}, fn response, {texts, pages, has_error} ->
        response_text = extract_text_from_response(response)
        response_has_error = has_error or (is_map(response) and Map.has_key?(response, "error"))
        {[response_text | texts], pages + 1, response_has_error}
      end)

    if has_error do
      {:error, :ocr_provider_failed}
    else
      {:ok, texts |> Enum.reverse() |> Enum.join("\n"), page_count}
    end
  end

  def parse_output_file(_body), do: {:error, :ocr_provider_failed}

  def parse_image_text(%{"responses" => [first | _]}) when is_map(first) do
    if Map.has_key?(first, "error") do
      {:error, :ocr_provider_failed}
    else
      {:ok, extract_text_from_response(first)}
    end
  end

  def parse_image_text(_), do: {:error, :ocr_provider_failed}

  def build_result(text, file_mime, document_type, bucket, storage_key, meta) do
    normalized_text = normalize_text(text) || ""
    text_length = String.length(normalized_text)
    has_text = text_length > 0
    line_count = if has_text, do: normalized_text |> String.split("\n") |> length(), else: 0

    word_count =
      if has_text, do: normalized_text |> String.split(~r/\s+/, trim: true) |> length(), else: 0

    %{
      ocr_payload: %{
        "provider" => "google_vision",
        "status" => "success",
        "feature" => "DOCUMENT_TEXT_DETECTION",
        "mode" => Map.get(meta, :mode, "image"),
        "file_mime" => file_mime,
        "document_type" => document_type,
        "gcs_uri" => "gs://#{bucket}/#{storage_key}",
        "has_text" => has_text,
        "text_length" => text_length,
        "page_count" => Map.get(meta, :page_count),
        "output_bucket" => Map.get(meta, :output_bucket),
        "output_prefix" => Map.get(meta, :output_prefix),
        "output_file_count" => Map.get(meta, :output_file_count)
      },
      extracted_data: %{
        "provider" => "google_vision",
        "status" => "success",
        "mode" => Map.get(meta, :mode, "image"),
        "document_type" => document_type,
        "has_text" => has_text,
        "text_length" => text_length,
        "line_count" => line_count,
        "word_count" => word_count,
        "page_count" => Map.get(meta, :page_count),
        "text_sha256" => sha256_hex(normalized_text)
      }
    }
  end

  defp extract_text_from_response(response) when is_map(response) do
    full_text = get_in(response, ["fullTextAnnotation", "text"])

    if is_binary(full_text) and full_text != "" do
      full_text
    else
      response
      |> get_in(["textAnnotations"])
      |> first_text_annotation()
    end
  end

  defp extract_text_from_response(_), do: ""

  defp first_text_annotation([%{"description" => value} | _]) when is_binary(value), do: value
  defp first_text_annotation(_), do: ""

  defp normalize_text(nil), do: nil

  defp normalize_text(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp normalize_text(value), do: value |> to_string() |> normalize_text()

  defp sha256_hex(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end
end
