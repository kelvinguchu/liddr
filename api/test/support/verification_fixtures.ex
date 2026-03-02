defmodule Liddr.VerificationFixtures do
  import Ecto.Query

  alias Decimal, as: D
  alias Liddr.Accounts.Driver
  alias Liddr.Accounts.User
  alias Liddr.Repo
  alias Liddr.Verification.VerificationApplication
  alias Liddr.Verification.VerificationDocument
  alias Liddr.Verification.VerificationRequirement

  def unique_phone do
    suffix =
      System.unique_integer([:positive])
      |> Integer.to_string()
      |> String.pad_leading(8, "0")
      |> String.slice(-8, 8)

    "2547" <> suffix
  end

  def unique_email(prefix \\ "user"),
    do: "#{prefix}_#{System.unique_integer([:positive])}@example.com"

  def insert_vehicle_category!(attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    slug = Map.get(attrs, :slug) || "cat_#{System.unique_integer([:positive])}"

    row =
      %{
        slug: slug,
        label: "Test Category",
        capacity: 4,
        base_fee_kes: D.new("20.00"),
        price_per_km_kes: D.new("20.00"),
        price_per_min_kes: D.new("3.00"),
        booking_fee_kes: D.new("10.00"),
        min_fare_kes: D.new("120.00"),
        weekly_sub_kes: 800,
        is_active: true,
        inserted_at: now,
        updated_at: now
      }
      |> Map.merge(attrs)
      |> Map.put(:inserted_at, now)
      |> Map.put(:updated_at, now)

    {1, [%{id: id}]} = Repo.insert_all("vehicle_categories", [row], returning: [:id])
    id
  end

  def create_user!(attrs \\ %{}) do
    defaults =
      case {Map.get(attrs, :phone), Map.get(attrs, :email)} do
        {nil, nil} -> %{phone: unique_phone()}
        _ -> %{}
      end

    %User{}
    |> User.registration_changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  def create_driver!(opts \\ []) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    user = Keyword.get(opts, :user) || create_user!()
    category_id = Keyword.get(opts, :vehicle_category_id) || insert_vehicle_category!()

    attrs = %{
      "user_id" => user.id,
      "vehicle_category_id" => category_id,
      "subscription_status" => Keyword.get(opts, :subscription_status, "inactive"),
      "is_available" => Keyword.get(opts, :is_available, false),
      "account_status" => Keyword.get(opts, :account_status, "pending"),
      "verification_status" => Keyword.get(opts, :verification_status, "pending"),
      "last_seen_at" => now
    }

    %Driver{}
    |> Driver.create_changeset(attrs)
    |> Repo.insert!()
  end

  def create_verification_application!(driver_id, opts \\ []) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %VerificationApplication{}
    |> VerificationApplication.create_changeset(%{
      "driver_id" => driver_id,
      "status" => Keyword.get(opts, :status, "pending"),
      "provider" => Keyword.get(opts, :provider, "internal"),
      "submitted_at" => Keyword.get(opts, :submitted_at, now)
    })
    |> Repo.insert!()
  end

  def create_verification_document!(driver_id, application_id, opts \\ []) do
    document_type = Keyword.get(opts, :document_type, "drivers_licence")
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    status = Keyword.get(opts, :status, "pending_review")
    default_scan_status = if status == "rejected", do: "infected", else: "clean"

    version =
      Repo.one(
        from d in VerificationDocument,
          where: d.application_id == ^application_id and d.document_type == ^document_type,
          select: max(d.version)
      ) || 0

    %VerificationDocument{}
    |> VerificationDocument.create_changeset(%{
      "application_id" => application_id,
      "driver_id" => driver_id,
      "document_type" => document_type,
      "version" => version + 1,
      "capture_source" => Keyword.get(opts, :capture_source, "camera_live"),
      "status" => status,
      "storage_key" =>
        Keyword.get(
          opts,
          :storage_key,
          "verification/docs/#{System.unique_integer([:positive])}.jpg"
        ),
      "scan_status" => Keyword.get(opts, :scan_status, default_scan_status),
      "scanned_at" => Keyword.get(opts, :scanned_at, now),
      "scan_engine" => Keyword.get(opts, :scan_engine, "test"),
      "scan_signature" => Keyword.get(opts, :scan_signature),
      "scan_error" => Keyword.get(opts, :scan_error)
    })
    |> Repo.insert!()
  end

  def create_verification_requirement!(document_type, attrs \\ %{}) do
    defaults = %{
      label: String.replace(document_type, "_", " ") |> String.capitalize(),
      required: true,
      requires_expiry: false,
      is_active: true,
      display_order: 10
    }

    Repo.insert!(
      struct!(
        VerificationRequirement,
        Map.merge(defaults, Map.put(attrs, :document_type, document_type))
      )
    )
  end

  def create_driver_and_application!(opts \\ []) do
    driver =
      create_driver!(
        user: Keyword.get(opts, :user),
        vehicle_category_id: Keyword.get(opts, :vehicle_category_id),
        subscription_status: Keyword.get(opts, :subscription_status, "inactive"),
        is_available: Keyword.get(opts, :is_available, false),
        account_status: Keyword.get(opts, :account_status, "pending"),
        verification_status: Keyword.get(opts, :verification_status, "pending")
      )

    application =
      create_verification_application!(
        driver.user_id,
        status: Keyword.get(opts, :application_status, "pending"),
        provider: Keyword.get(opts, :provider, "internal")
      )

    {driver, application}
  end

  def create_driver_application_and_document!(opts \\ []) do
    {driver, application} =
      create_driver_and_application!(
        user: Keyword.get(opts, :user),
        vehicle_category_id: Keyword.get(opts, :vehicle_category_id),
        account_status: Keyword.get(opts, :account_status, "pending"),
        verification_status: Keyword.get(opts, :verification_status, "pending"),
        application_status: Keyword.get(opts, :application_status, "under_review")
      )

    document =
      create_verification_document!(
        driver.user_id,
        application.id,
        document_type: Keyword.get(opts, :document_type, "drivers_licence"),
        status: Keyword.get(opts, :document_status, "pending_review")
      )

    {driver, application, document}
  end

  def create_driver_application_and_reviewer!(opts \\ []) do
    {driver, application} =
      create_driver_and_application!(
        user: Keyword.get(opts, :user),
        vehicle_category_id: Keyword.get(opts, :vehicle_category_id),
        account_status: Keyword.get(opts, :account_status, "pending"),
        verification_status: Keyword.get(opts, :verification_status, "under_review"),
        application_status: Keyword.get(opts, :application_status, "under_review")
      )

    reviewer = Keyword.get(opts, :reviewer) || create_user!(%{email: unique_email("ops")})
    {driver, application, reviewer}
  end

  def create_driver_application_document_and_reviewer!(opts \\ []) do
    {driver, application, document} =
      create_driver_application_and_document!(
        user: Keyword.get(opts, :user),
        vehicle_category_id: Keyword.get(opts, :vehicle_category_id),
        account_status: Keyword.get(opts, :account_status, "pending"),
        verification_status: Keyword.get(opts, :verification_status, "pending"),
        application_status: Keyword.get(opts, :application_status, "under_review"),
        document_status: Keyword.get(opts, :document_status, "pending_review"),
        document_type: Keyword.get(opts, :document_type, "drivers_licence")
      )

    reviewer = Keyword.get(opts, :reviewer) || create_user!(%{email: unique_email("ops")})
    {driver, application, document, reviewer}
  end
end
