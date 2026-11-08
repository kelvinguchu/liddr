defmodule Liddr.Verification.VerificationDocument do
  use Ecto.Schema
  import Ecto.Changeset

  @capture_sources ~w(camera_live ops_upload)
  @statuses ~w(uploaded pending_review validated rejected expired resubmission_required)
  @scan_statuses ~w(pending clean infected failed skipped)

  schema "verification_documents" do
    field :document_type, :string
    field :version, :integer
    field :capture_source, :string
    field :status, :string
    field :storage_key, :string
    field :checksum_sha256, :string
    field :file_mime, :string
    field :file_size_bytes, :integer
    field :expires_on, :date
    field :reviewed_at, :utc_datetime_usec
    field :rejection_reason, :string
    field :ocr_payload, :map, default: %{}
    field :extracted_data, :map, default: %{}
    field :capture_metadata, :map, default: %{}
    field :scan_status, :string, default: "pending"
    field :scanned_at, :utc_datetime_usec
    field :scan_engine, :string
    field :scan_signature, :string
    field :scan_error, :string

    belongs_to :application, Liddr.Verification.VerificationApplication
    field :driver_id, :id

    belongs_to :driver, Liddr.Accounts.Driver,
      define_field: false,
      foreign_key: :driver_id,
      references: :user_id

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(document, attrs) do
    document
    |> cast(attrs, [
      :application_id,
      :driver_id,
      :document_type,
      :version,
      :capture_source,
      :status,
      :storage_key,
      :checksum_sha256,
      :file_mime,
      :file_size_bytes,
      :expires_on,
      :reviewed_at,
      :rejection_reason,
      :ocr_payload,
      :extracted_data,
      :capture_metadata,
      :scan_status,
      :scanned_at,
      :scan_engine,
      :scan_signature,
      :scan_error
    ])
    |> validate_required([
      :application_id,
      :driver_id,
      :document_type,
      :version,
      :capture_source,
      :status,
      :storage_key
    ])
    |> validate_number(:version, greater_than_or_equal_to: 1)
    |> validate_inclusion(:capture_source, @capture_sources)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:scan_status, @scan_statuses)
    |> validate_number(:file_size_bytes, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:application_id)
    |> foreign_key_constraint(:driver_id)
    |> unique_constraint(:version,
      name: :verification_documents_application_id_document_type_version_index
    )
    |> check_constraint(:version, name: :verification_documents_version_valid)
    |> check_constraint(:capture_source, name: :verification_documents_capture_source_valid)
    |> check_constraint(:status, name: :verification_documents_status_valid)
    |> check_constraint(:file_size_bytes, name: :verification_documents_size_non_negative)
  end
end
