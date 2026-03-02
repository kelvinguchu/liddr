defmodule Liddr.Moderation.ReportReview do
  use Ecto.Schema
  import Ecto.Changeset

  @decisions ~w(needs_more_info no_action warning temporary_suspension permanent_ban escalate dismiss)

  schema "report_reviews" do
    field :decision, :string
    field :severity_level, :integer
    field :reason_code, :string
    field :notes, :string
    field :decided_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    belongs_to :report, Liddr.Moderation.Report
    belongs_to :reviewer_user, Liddr.Accounts.User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def create_changeset(report_review, attrs) do
    report_review
    |> cast(attrs, [
      :report_id,
      :reviewer_user_id,
      :decision,
      :severity_level,
      :reason_code,
      :notes,
      :decided_at,
      :metadata
    ])
    |> validate_required([:report_id, :reviewer_user_id, :decision, :decided_at])
    |> validate_inclusion(:decision, @decisions)
    |> validate_number(:severity_level, greater_than_or_equal_to: 1, less_than_or_equal_to: 5)
    |> foreign_key_constraint(:report_id)
    |> foreign_key_constraint(:reviewer_user_id)
    |> check_constraint(:decision, name: :report_reviews_decision_valid)
    |> check_constraint(:severity_level, name: :report_reviews_severity_level_range)
  end
end
