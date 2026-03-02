defmodule Liddr.Moderation.UserEnforcement do
  use Ecto.Schema
  import Ecto.Changeset

  @scopes ~w(platform rides delivery payments communication)
  @actions ~w(warning feature_restriction temporary_suspension permanent_ban)
  @statuses ~w(active expired lifted rejected)

  schema "user_enforcements" do
    field :scope, :string
    field :action, :string
    field :status, :string
    field :reason_code, :string
    field :reason_text, :string
    field :starts_at, :utc_datetime_usec
    field :ends_at, :utc_datetime_usec
    field :lifted_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    belongs_to :user, Liddr.Accounts.User
    belongs_to :report, Liddr.Moderation.Report
    belongs_to :actor_user, Liddr.Accounts.User
    belongs_to :lifted_by_user, Liddr.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(user_enforcement, attrs) do
    user_enforcement
    |> cast(attrs, [
      :user_id,
      :report_id,
      :actor_user_id,
      :scope,
      :action,
      :status,
      :reason_code,
      :reason_text,
      :starts_at,
      :ends_at,
      :lifted_at,
      :lifted_by_user_id,
      :metadata
    ])
    |> validate_required([:user_id, :action, :starts_at, :scope, :status])
    |> validate_inclusion(:scope, @scopes)
    |> validate_inclusion(:action, @actions)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:report_id)
    |> foreign_key_constraint(:actor_user_id)
    |> foreign_key_constraint(:lifted_by_user_id)
    |> check_constraint(:scope, name: :user_enforcements_scope_valid)
    |> check_constraint(:action, name: :user_enforcements_action_valid)
    |> check_constraint(:status, name: :user_enforcements_status_valid)
    |> check_constraint(:ends_at, name: :user_enforcements_temporal_window_valid)
    |> check_constraint(:ends_at, name: :user_enforcements_temporary_requires_end)
    |> check_constraint(:ends_at, name: :user_enforcements_permanent_without_end)
    |> check_constraint(:lifted_at, name: :user_enforcements_lifted_at_valid)
  end
end
