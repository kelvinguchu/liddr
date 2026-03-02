defmodule Liddr.Verification.Onboarding.ApplicationState do
  import Ecto.Query

  alias Liddr.Accounts.Driver
  alias Liddr.Repo
  alias Liddr.Verification.Shared
  alias Liddr.Verification.VerificationApplication
  alias Liddr.Verification.VerificationDocument
  alias Liddr.Verification.VerificationRequirement

  @active_application_statuses ~w(pending under_review resubmission_required)
  @document_present_statuses ~w(uploaded pending_review validated resubmission_required)

  def get_or_create_active_application!(driver_user_id, now) do
    existing_application =
      Repo.one(
        from a in VerificationApplication,
          where: a.driver_id == ^driver_user_id and a.status in ^@active_application_statuses,
          order_by: [desc: a.inserted_at],
          limit: 1,
          lock: "FOR UPDATE"
      )

    case existing_application do
      %VerificationApplication{} = application ->
        application

      nil ->
        attrs = %{
          "driver_id" => driver_user_id,
          "status" => "pending",
          "provider" => "internal",
          "submitted_at" => now
        }

        %VerificationApplication{}
        |> VerificationApplication.create_changeset(attrs)
        |> Repo.insert()
        |> case do
          {:ok, application} -> application
          {:error, changeset} -> Repo.rollback(changeset)
        end
    end
  end

  def resolve_application!(driver_user_id, attrs) do
    application_id =
      attrs
      |> Shared.get_value(:application_id)
      |> Shared.parse_integer()

    application =
      cond do
        is_integer(application_id) ->
          Repo.get_by(VerificationApplication, id: application_id, driver_id: driver_user_id)

        true ->
          Repo.one(
            from a in VerificationApplication,
              where: a.driver_id == ^driver_user_id and a.status in ^@active_application_statuses,
              order_by: [desc: a.inserted_at],
              limit: 1
          )
      end

    case application do
      %VerificationApplication{} = app -> app
      nil when is_integer(application_id) -> Repo.rollback(:application_not_found)
      nil -> Repo.rollback(:no_active_application)
    end
  end

  def next_document_version(application_id, document_type) do
    Repo.one(
      from d in VerificationDocument,
        where:
          d.application_id == ^application_id and
            d.document_type == ^document_type,
        select: max(d.version)
    ) || 0
  end

  def maybe_promote_application_to_under_review!(application, driver, now) do
    requirement_types =
      Repo.all(
        from r in VerificationRequirement,
          where: r.is_active == true and r.required == true,
          select: r.document_type
      )

    present_types =
      Repo.all(
        from d in VerificationDocument,
          where:
            d.application_id == ^application.id and
              d.status in ^@document_present_statuses,
          select: d.document_type,
          distinct: true
      )
      |> MapSet.new()

    has_all_required = Enum.all?(requirement_types, &MapSet.member?(present_types, &1))

    if has_all_required and application.status == "pending" do
      updated_application =
        application
        |> VerificationApplication.create_changeset(%{
          "status" => "under_review",
          "submitted_at" => application.submitted_at || now
        })
        |> Repo.update()
        |> case do
          {:ok, app} -> app
          {:error, changeset} -> Repo.rollback(changeset)
        end

      _updated_driver =
        driver
        |> Driver.create_changeset(%{
          "verification_status" => "under_review",
          "last_seen_at" => now
        })
        |> Repo.update()
        |> case do
          {:ok, updated_driver} -> updated_driver
          {:error, changeset} -> Repo.rollback(changeset)
        end

      updated_application
    else
      application
    end
  end
end
