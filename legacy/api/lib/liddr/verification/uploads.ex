defmodule Liddr.Verification.Uploads do
  alias Liddr.Repo
  alias Liddr.Storage.GCS
  alias Liddr.Storage.GCS.ObjectMetadata
  alias Liddr.Verification.Shared
  alias Liddr.Verification.VerificationRequirement

  @default_upload_prefix "verification/docs"
  @default_upload_ttl_seconds 900
  @default_max_file_size_bytes 10_485_760
  @default_allowed_mime_types ["image/jpeg", "image/png", "application/pdf"]

  def prepare_document_upload(driver_user_id, attrs) do
    with {:ok, requirement} <- resolve_requirement(attrs),
         {:ok, content_type} <- resolve_content_type(attrs),
         {:ok, file_size_bytes} <- resolve_file_size(attrs),
         :ok <- validate_file_size(file_size_bytes),
         :ok <- validate_content_type(content_type),
         {:ok, storage_key} <-
           generate_storage_key(driver_user_id, requirement.document_type, content_type),
         {:ok, signed} <-
           gcs_presigner().presign_put_upload(
             storage_key,
             content_type,
             ttl_seconds: upload_ttl_seconds()
           ) do
      {:ok,
       %{
         document_type: requirement.document_type,
         storage_key: signed.storage_key,
         upload_url: signed.upload_url,
         required_headers: signed.required_headers,
         expires_at: signed.expires_at,
         max_file_size_bytes: max_file_size_bytes(),
         allowed_mime_types: allowed_mime_types()
       }}
    end
  end

  def verify_uploaded_object(driver_user_id, document_type, attrs) do
    with {:ok, storage_key} <- ensure_storage_key_allowed(driver_user_id, document_type, attrs),
         {:ok, claimed_content_type} <- resolve_content_type(attrs),
         {:ok, claimed_file_size_bytes} <- resolve_file_size(attrs),
         {:ok, metadata} <- metadata_fetcher().fetch_object_metadata(storage_key),
         :ok <- validate_content_type(metadata.content_type),
         :ok <- validate_file_size(metadata.file_size_bytes),
         :ok <- validate_claimed_content_type(claimed_content_type, metadata.content_type),
         :ok <- validate_claimed_file_size(claimed_file_size_bytes, metadata.file_size_bytes) do
      {:ok,
       %{
         storage_key: storage_key,
         file_mime: metadata.content_type,
         file_size_bytes: metadata.file_size_bytes,
         object_metadata: %{
           generation: metadata.generation,
           etag: metadata.etag,
           md5_hash: metadata.md5_hash,
           crc32c: metadata.crc32c
         }
       }}
    end
  end

  def ensure_storage_key_allowed(driver_user_id, document_type, attrs) do
    storage_key =
      attrs
      |> Shared.get_value(:storage_key)
      |> Shared.normalize_text()

    cond do
      is_nil(storage_key) ->
        {:error, :missing_storage_key}

      true ->
        validate_storage_key_scope(storage_key, driver_user_id, document_type)
    end
  end

  defp validate_storage_key_scope(storage_key, driver_user_id, document_type) do
    with {:ok, storage_key} <- GCS.validate_object_key(storage_key),
         [driver_segment, document_segment, filename] <-
           storage_key
           |> String.split("/", trim: true)
           |> Enum.drop(prefix_segments_length()),
         true <- driver_segment == to_string(driver_user_id),
         true <- document_segment == document_type,
         true <- valid_filename?(filename) do
      {:ok, storage_key}
    else
      _ ->
        {:error, :invalid_storage_key}
    end
  end

  defp resolve_requirement(attrs) do
    document_type =
      attrs
      |> Shared.get_value(:document_type)
      |> Shared.normalize_text()

    case Repo.get_by(VerificationRequirement, document_type: document_type, is_active: true) do
      %VerificationRequirement{} = requirement -> {:ok, requirement}
      _ -> {:error, :invalid_document_type}
    end
  end

  defp resolve_content_type(attrs) do
    value =
      attrs
      |> Shared.get_value(:file_mime)
      |> Shared.normalize_text()

    if is_binary(value), do: {:ok, String.downcase(value)}, else: {:error, :missing_file_mime}
  end

  defp resolve_file_size(attrs) do
    parsed =
      attrs
      |> Shared.get_value(:file_size_bytes)
      |> Shared.parse_integer()

    if is_integer(parsed) and parsed > 0 do
      {:ok, parsed}
    else
      {:error, :invalid_file_size_bytes}
    end
  end

  defp validate_file_size(size) do
    if size > max_file_size_bytes(), do: {:error, :file_too_large}, else: :ok
  end

  defp validate_content_type(content_type) do
    if content_type in allowed_mime_types(), do: :ok, else: {:error, :invalid_file_mime}
  end

  defp validate_claimed_content_type(content_type, content_type), do: :ok

  defp validate_claimed_content_type(_claimed, _actual),
    do: {:error, :uploaded_file_mime_mismatch}

  defp validate_claimed_file_size(size, size), do: :ok
  defp validate_claimed_file_size(_claimed, _actual), do: {:error, :uploaded_file_size_mismatch}

  defp generate_storage_key(driver_user_id, document_type, content_type) do
    extension =
      case content_type do
        "image/jpeg" -> "jpg"
        "image/png" -> "png"
        "application/pdf" -> "pdf"
        _ -> "bin"
      end

    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    random = System.unique_integer([:positive]) |> Integer.to_string()

    key =
      [
        upload_prefix(),
        to_string(driver_user_id),
        document_type,
        "#{timestamp}_#{random}.#{extension}"
      ]
      |> Enum.map(&String.trim(&1, "/"))
      |> Enum.join("/")

    {:ok, key}
  end

  defp metadata_fetcher do
    Application.get_env(:liddr, :gcs_object_metadata_fetcher, ObjectMetadata)
  end

  defp gcs_presigner do
    Application.get_env(:liddr, :gcs_upload_presigner, GCS)
  end

  defp prefix_segments_length do
    upload_prefix()
    |> String.split("/", trim: true)
    |> length()
  end

  defp valid_filename?(filename) do
    filename != "" and not String.contains?(filename, ["/", "\\"])
  end

  defp upload_prefix do
    case System.get_env("GCS_UPLOAD_PREFIX") do
      nil ->
        @default_upload_prefix

      value ->
        normalized = String.trim(value)
        if normalized == "", do: @default_upload_prefix, else: String.trim(normalized, "/")
    end
  end

  defp upload_ttl_seconds do
    case System.get_env("GCS_SIGNED_URL_TTL_SECONDS") do
      nil ->
        @default_upload_ttl_seconds

      value ->
        case Integer.parse(value) do
          {seconds, ""} when seconds > 0 -> seconds
          _ -> @default_upload_ttl_seconds
        end
    end
  end

  defp max_file_size_bytes do
    case System.get_env("GCS_MAX_FILE_SIZE_BYTES") do
      nil ->
        @default_max_file_size_bytes

      value ->
        case Integer.parse(value) do
          {size, ""} when size > 0 -> size
          _ -> @default_max_file_size_bytes
        end
    end
  end

  defp allowed_mime_types do
    case System.get_env("GCS_ALLOWED_MIME_TYPES") do
      nil ->
        @default_allowed_mime_types

      value ->
        parsed =
          value
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.map(&String.downcase/1)
          |> Enum.reject(&(&1 == ""))

        if parsed == [], do: @default_allowed_mime_types, else: parsed
    end
  end
end
