defmodule Liddr.Disputes.Compensation do
  use Ecto.Schema
  import Ecto.Changeset

  @types ~w(refund_full refund_partial credit_note)
  @statuses ~w(approved paid cancelled)
  @processing_channels ~w(manual_ops mpesa_reversal wallet_credit bank_transfer)

  schema "dispute_compensations" do
    field :compensation_type, :string
    field :status, :string
    field :amount_kes, :decimal
    field :currency, :string
    field :reason_code, :string
    field :reason_text, :string
    field :metadata, :map, default: %{}
    field :processed_at, :utc_datetime_usec
    field :processing_reference, :string
    field :processing_channel, :string

    belongs_to :report, Liddr.Moderation.Report
    belongs_to :ride, Liddr.Rides.Ride
    belongs_to :beneficiary_user, Liddr.Accounts.User
    belongs_to :counterparty_user, Liddr.Accounts.User
    belongs_to :actor_user, Liddr.Accounts.User
    belongs_to :processed_by_user, Liddr.Accounts.User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def create_changeset(compensation, attrs) do
    compensation
    |> cast(attrs, [
      :report_id,
      :ride_id,
      :beneficiary_user_id,
      :counterparty_user_id,
      :actor_user_id,
      :compensation_type,
      :status,
      :amount_kes,
      :currency,
      :reason_code,
      :reason_text,
      :metadata,
      :processed_at,
      :processed_by_user_id,
      :processing_reference,
      :processing_channel
    ])
    |> validate_required([
      :report_id,
      :ride_id,
      :beneficiary_user_id,
      :compensation_type,
      :status,
      :amount_kes,
      :currency
    ])
    |> validate_inclusion(:compensation_type, @types)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:amount_kes, greater_than: 0)
    |> validate_inclusion(:currency, ["KES"])
    |> unique_constraint(:report_id, name: :dispute_compensations_unique_report_idx)
    |> foreign_key_constraint(:report_id)
    |> foreign_key_constraint(:ride_id)
    |> foreign_key_constraint(:beneficiary_user_id)
    |> foreign_key_constraint(:counterparty_user_id)
    |> foreign_key_constraint(:actor_user_id)
    |> foreign_key_constraint(:processed_by_user_id)
    |> check_constraint(:compensation_type, name: :dispute_compensations_type_valid)
    |> check_constraint(:status, name: :dispute_compensations_status_valid)
    |> check_constraint(:amount_kes, name: :dispute_compensations_amount_positive)
    |> check_constraint(:currency, name: :dispute_compensations_currency_kes)
    |> check_constraint(:processed_at, name: :dispute_compensations_processed_presence)
  end

  def transition_changeset(compensation, attrs) do
    compensation
    |> cast(attrs, [
      :status,
      :processed_at,
      :processed_by_user_id,
      :reason_text,
      :metadata,
      :processing_reference,
      :processing_channel
    ])
    |> validate_required([:status, :processed_at, :processed_by_user_id])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:processing_channel, @processing_channels)
    |> foreign_key_constraint(:processed_by_user_id)
    |> check_constraint(:status, name: :dispute_compensations_status_valid)
    |> check_constraint(:processed_at, name: :dispute_compensations_processed_presence)
    |> check_constraint(:processing_channel,
      name: :dispute_compensations_processing_channel_valid
    )
    |> check_constraint(:processing_reference,
      name: :dispute_compensations_paid_requires_processing_reference
    )
  end
end
