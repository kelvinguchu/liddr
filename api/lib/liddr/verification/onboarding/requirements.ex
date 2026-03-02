defmodule Liddr.Verification.Onboarding.Requirements do
  import Ecto.Query

  alias Liddr.Accounts.Driver
  alias Liddr.Repo
  alias Liddr.Verification.Shared
  alias Liddr.Verification.VerificationApplication
  alias Liddr.Verification.VerificationDocument
  alias Liddr.Verification.VerificationRequirement

  @active_application_statuses ~w(pending under_review resubmission_required)
  @document_present_statuses ~w(uploaded pending_review validated resubmission_required)

  def resolve_requirement!(attrs) do
    document_type =
      attrs
      |> Shared.get_value(:document_type)
      |> Shared.normalize_text()

    requirement =
      Repo.get_by(VerificationRequirement, document_type: document_type, is_active: true)

    if requirement do
      requirement
    else
      Repo.rollback(:invalid_document_type)
    end
  end

  def get_status(driver_user_id) do
    with %Driver{} = driver <- Repo.get(Driver, driver_user_id) do
      application =
        Repo.one(
          from a in VerificationApplication,
            where: a.driver_id == ^driver_user_id and a.status in ^@active_application_statuses,
            order_by: [desc: a.inserted_at],
            limit: 1
        )

      requirements =
        Repo.all(
          from r in VerificationRequirement,
            where: r.is_active == true,
            order_by: [asc: r.display_order, asc: r.id]
        )

      latest_documents =
        Repo.all(
          from d in VerificationDocument,
            where: d.driver_id == ^driver_user_id,
            distinct: d.document_type,
            order_by: [asc: d.document_type, desc: d.version, desc: d.inserted_at]
        )
        |> Map.new(fn d -> {d.document_type, d} end)

      requirement_states =
        Enum.map(requirements, fn requirement ->
          latest_document = Map.get(latest_documents, requirement.document_type)
          uploaded = document_present?(latest_document)

          %{
            document_type: requirement.document_type,
            label: requirement.label,
            required: requirement.required,
            requires_expiry: requirement.requires_expiry,
            uploaded: uploaded,
            latest_document_status: latest_document && latest_document.status,
            latest_document_version: latest_document && latest_document.version,
            latest_document_expires_on: latest_document && latest_document.expires_on
          }
        end)

      missing_required_document_types =
        requirement_states
        |> Enum.filter(&(&1.required and !&1.uploaded))
        |> Enum.map(& &1.document_type)

      {:ok,
       %{
         driver: %{
           driver_id: driver.user_id,
           account_status: driver.account_status,
           verification_status: driver.verification_status
         },
         application:
           application &&
             %{
               id: application.id,
               status: application.status,
               provider: application.provider,
               submitted_at: application.submitted_at,
               decided_at: application.decided_at,
               decision_reason: application.decision_reason
             },
         requirements: requirement_states,
         missing_required_document_types: missing_required_document_types
       }}
    else
      nil ->
        {:error, :driver_profile_not_found}
    end
  end

  defp document_present?(nil), do: false

  defp document_present?(%VerificationDocument{status: status}),
    do: status in @document_present_statuses
end
