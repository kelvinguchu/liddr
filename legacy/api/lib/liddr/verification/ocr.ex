defmodule Liddr.Verification.OCR do
  alias Liddr.Verification.OCR.GoogleVision

  def extract_storage_key(storage_key, opts \\ [])

  def extract_storage_key(storage_key, opts) when is_binary(storage_key) do
    file_mime = opts |> Keyword.get(:file_mime) |> normalize_file_mime()
    document_type = opts |> Keyword.get(:document_type) |> normalize_text()

    cond do
      not ocr_enabled?() ->
        {:ok, skipped_result("disabled", document_type)}

      file_mime in [nil, ""] ->
        {:ok, skipped_result("missing_file_mime", document_type)}

      file_mime == "application/pdf" and not pdf_ocr_enabled?() ->
        {:ok, skipped_result("pdf_ocr_disabled", document_type)}

      not supported_file_mime?(file_mime) ->
        {:ok, skipped_result("unsupported_file_mime", document_type)}

      true ->
        run_google_vision(storage_key, file_mime, document_type)
    end
  end

  def extract_storage_key(_storage_key, _opts), do: {:error, :invalid_storage_key}

  def skipped_result(reason, document_type \\ nil) do
    %{
      ocr_payload: %{
        "provider" => "google_vision",
        "status" => "skipped",
        "reason" => reason,
        "document_type" => document_type
      },
      extracted_data: %{
        "provider" => "google_vision",
        "status" => "skipped",
        "reason" => reason,
        "document_type" => document_type
      }
    }
  end

  defp run_google_vision(storage_key, file_mime, document_type) do
    case GoogleVision.extract_storage_key(storage_key,
           file_mime: file_mime,
           document_type: document_type
         ) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        {:ok,
         %{
           ocr_payload: %{
             "provider" => "google_vision",
             "status" => "failed",
             "reason" => to_string(reason),
             "document_type" => document_type
           },
           extracted_data: %{
             "provider" => "google_vision",
             "status" => "failed",
             "reason" => to_string(reason),
             "document_type" => document_type
           }
         }}
    end
  end

  defp ocr_enabled? do
    case System.get_env("OCR_ENABLED") do
      nil ->
        Application.get_env(:liddr, :ocr_enabled, false)

      value ->
        String.downcase(String.trim(value)) in ["1", "true", "yes", "on"]
    end
  end

  defp pdf_ocr_enabled? do
    case System.get_env("OCR_PDF_ENABLED") do
      nil ->
        Application.get_env(:liddr, :ocr_pdf_enabled, false)

      value ->
        String.downcase(String.trim(value)) in ["1", "true", "yes", "on"]
    end
  end

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

  defp normalize_file_mime(nil), do: nil

  defp normalize_file_mime(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_file_mime(value), do: value |> to_string() |> normalize_file_mime()

  defp supported_file_mime?(file_mime),
    do: file_mime in ["image/jpeg", "image/png", "application/pdf"]
end
