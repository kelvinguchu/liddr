defmodule Liddr.Rides.SendProofUploads do
  @moduledoc false

  alias Liddr.Repo
  alias Liddr.Rides.Ride
  alias Liddr.Rides.SendDeliverySupport
  alias Liddr.Storage.GCS
  alias Liddr.Storage.GCS.ObjectMetadata
  alias Liddr.Subscriptions.PaymentUtils

  @key_prefix ["send", "proofs"]
  @proof_kinds ~w(pickup dropoff)
  @active_statuses ~w(arrived in_progress)
  @extensions %{"image/jpeg" => "jpg", "image/png" => "png"}
  @max_file_size_bytes 10_485_760
  @upload_ttl_seconds 900

  def prepare_upload(driver_user_id, ride_id, attrs) do
    with {:ok, proof_kind} <- fetch_proof_kind(attrs),
         {:ok, content_type} <- fetch_content_type(attrs),
         :ok <- validate_file_size(PaymentUtils.get_value(attrs, :file_size_bytes)),
         {:ok, ride} <- fetch_driver_send_ride(driver_user_id, ride_id),
         {:ok, signed} <-
           presigner().presign_put_upload(
             storage_key(driver_user_id, ride.id, proof_kind, content_type),
             content_type,
             ttl_seconds: @upload_ttl_seconds
           ) do
      {:ok,
       %{
         proof_kind: proof_kind,
         storage_key: signed.storage_key,
         upload_url: signed.upload_url,
         required_headers: signed.required_headers,
         expires_at: signed.expires_at,
         max_file_size_bytes: @max_file_size_bytes
       }}
    end
  end

  def verify_uploaded_proof(driver_user_id, ride_id, proof_kind, storage_key) do
    with {:ok, key} <- validate_key_scope(driver_user_id, ride_id, proof_kind, storage_key),
         {:ok, metadata} <- metadata_fetcher().fetch_object_metadata(key),
         :ok <- validate_content_type(metadata.content_type),
         :ok <- validate_file_size(metadata.file_size_bytes) do
      {:ok, key}
    end
  end

  defp fetch_proof_kind(attrs) do
    kind = attrs |> PaymentUtils.get_value(:proof_kind) |> PaymentUtils.normalize_text()
    if kind in @proof_kinds, do: {:ok, kind}, else: {:error, :invalid_proof_kind}
  end

  defp fetch_content_type(attrs) do
    case attrs |> PaymentUtils.get_value(:file_mime) |> PaymentUtils.normalize_text() do
      nil ->
        {:error, :missing_file_mime}

      value ->
        content_type = String.downcase(value)
        with :ok <- validate_content_type(content_type), do: {:ok, content_type}
    end
  end

  defp validate_content_type(content_type) do
    if Map.has_key?(@extensions, content_type), do: :ok, else: {:error, :invalid_file_mime}
  end

  defp validate_file_size(size) when is_binary(size) do
    case Integer.parse(String.trim(size)) do
      {parsed, ""} -> validate_file_size(parsed)
      _ -> {:error, :invalid_file_size_bytes}
    end
  end

  defp validate_file_size(size) when is_integer(size) and size > @max_file_size_bytes,
    do: {:error, :file_too_large}

  defp validate_file_size(size) when is_integer(size) and size > 0, do: :ok
  defp validate_file_size(_size), do: {:error, :invalid_file_size_bytes}

  defp fetch_driver_send_ride(driver_user_id, ride_id) do
    with {parsed_id, ""} <- Integer.parse(to_string(ride_id)),
         %Ride{driver_id: ^driver_user_id, status: status} = ride
         when status in @active_statuses <- Repo.get(Ride, parsed_id),
         true <- SendDeliverySupport.send_ride?(ride) do
      {:ok, ride}
    else
      %Ride{driver_id: ^driver_user_id} -> {:error, :send_pickup_proof_not_allowed}
      %Ride{} -> {:error, :ride_not_assigned_to_driver}
      false -> {:error, :send_ride_required}
      _ -> {:error, :ride_not_found}
    end
  end

  defp storage_key(driver_user_id, ride_id, proof_kind, content_type) do
    token = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
    filename = "#{driver_user_id}_#{token}.#{Map.fetch!(@extensions, content_type)}"
    Enum.join(@key_prefix ++ [to_string(ride_id), proof_kind, filename], "/")
  end

  defp validate_key_scope(driver_user_id, ride_id, proof_kind, storage_key) do
    with {:ok, key} <- GCS.validate_object_key(storage_key),
         segments = String.split(key, "/"),
         true <- List.starts_with?(segments, @key_prefix),
         [segment_ride_id, ^proof_kind, filename] <- Enum.drop(segments, length(@key_prefix)),
         true <- segment_ride_id == to_string(ride_id),
         true <- String.starts_with?(filename, "#{driver_user_id}_") do
      {:ok, key}
    else
      _ -> {:error, :invalid_storage_key}
    end
  end

  defp presigner, do: Application.get_env(:liddr, :gcs_upload_presigner, GCS)

  defp metadata_fetcher,
    do: Application.get_env(:liddr, :gcs_object_metadata_fetcher, ObjectMetadata)
end
