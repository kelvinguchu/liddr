defmodule Liddr.Moderation.Report do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(submitted triaged under_review resolved dismissed withdrawn)
  @sources ~w(in_app support system web)
  @incident_types ~w(safety conduct fraud payment vehicle account other)
  @context_types ~w(ride delivery subscription profile other)
  @resolution_outcomes ~w(no_action warning temporary_suspension permanent_ban escalated)

  schema "reports" do
    field :reported_driver_id, :id
    field :status, :string
    field :severity_level, :integer
    field :source, :string
    field :incident_type, :string
    field :context_type, :string
    field :context_reference, :string
    field :incident_at, :utc_datetime_usec
    field :description, :string
    field :reporter_contact_opt_in, :boolean
    field :is_anonymous_to_reported, :boolean
    field :triaged_at, :utc_datetime_usec
    field :resolved_at, :utc_datetime_usec
    field :resolution_outcome, :string
    field :resolution_summary, :string
    field :metadata, :map, default: %{}

    belongs_to :reporter_user, Liddr.Accounts.User
    belongs_to :reported_user, Liddr.Accounts.User
    belongs_to :category, Liddr.Moderation.ReportCategory
    belongs_to :assigned_reviewer_user, Liddr.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(report, attrs) do
    report
    |> cast(attrs, [
      :reporter_user_id,
      :reported_user_id,
      :reported_driver_id,
      :category_id,
      :status,
      :severity_level,
      :source,
      :incident_type,
      :context_type,
      :context_reference,
      :incident_at,
      :description,
      :reporter_contact_opt_in,
      :is_anonymous_to_reported,
      :assigned_reviewer_user_id,
      :triaged_at,
      :resolved_at,
      :resolution_outcome,
      :resolution_summary,
      :metadata
    ])
    |> validate_required([
      :reporter_user_id,
      :reported_user_id,
      :category_id,
      :severity_level,
      :description
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:severity_level, greater_than_or_equal_to: 1, less_than_or_equal_to: 5)
    |> validate_inclusion(:source, @sources)
    |> validate_inclusion(:incident_type, @incident_types)
    |> validate_context_type()
    |> validate_resolution_outcome()
    |> foreign_key_constraint(:reporter_user_id)
    |> foreign_key_constraint(:reported_user_id)
    |> foreign_key_constraint(:reported_driver_id)
    |> foreign_key_constraint(:category_id)
    |> check_constraint(:reporter_user_id, name: :reports_reporter_not_target)
  end

  defp validate_context_type(changeset) do
    case get_field(changeset, :context_type) do
      nil -> changeset
      _value -> validate_inclusion(changeset, :context_type, @context_types)
    end
  end

  defp validate_resolution_outcome(changeset) do
    case get_field(changeset, :resolution_outcome) do
      nil -> changeset
      _ -> validate_inclusion(changeset, :resolution_outcome, @resolution_outcomes)
    end
  end
end
