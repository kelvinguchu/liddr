defmodule Liddr.Subscriptions.SubscriptionPayment do
  use Ecto.Schema
  import Ecto.Changeset

  @providers ~w(mpesa)
  @channels ~w(stk_push c2b)
  @statuses ~w(initiated pending_callback success failed cancelled timeout)

  schema "subscription_payments" do
    field :provider, :string
    field :payment_channel, :string
    field :status, :string
    field :amount_kes, :decimal
    field :currency, :string
    field :phone_e164, :string
    field :merchant_request_id, :string
    field :checkout_request_id, :string
    field :mpesa_receipt_number, :string
    field :transaction_id, :string
    field :result_code, :integer
    field :result_desc, :string
    field :conversation_id, :string
    field :originator_conversation_id, :string
    field :requested_at, :utc_datetime_usec
    field :callback_received_at, :utc_datetime_usec
    field :paid_at, :utc_datetime_usec
    field :request_payload, :map, default: %{}
    field :callback_payload, :map
    field :status_query_payload, :map

    belongs_to :subscription, Liddr.Subscriptions.Subscription

    belongs_to :driver, Liddr.Accounts.Driver,
      define_field: false,
      foreign_key: :driver_id,
      references: :user_id

    field :driver_id, :id

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(payment, attrs) do
    payment
    |> cast(attrs, [
      :subscription_id,
      :driver_id,
      :provider,
      :payment_channel,
      :status,
      :amount_kes,
      :currency,
      :phone_e164,
      :merchant_request_id,
      :checkout_request_id,
      :mpesa_receipt_number,
      :transaction_id,
      :result_code,
      :result_desc,
      :conversation_id,
      :originator_conversation_id,
      :requested_at,
      :callback_received_at,
      :paid_at,
      :request_payload,
      :callback_payload,
      :status_query_payload
    ])
    |> validate_required([
      :subscription_id,
      :driver_id,
      :provider,
      :payment_channel,
      :status,
      :amount_kes,
      :currency,
      :requested_at
    ])
    |> validate_inclusion(:provider, @providers)
    |> validate_inclusion(:payment_channel, @channels)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:subscription_id)
    |> foreign_key_constraint(:driver_id)
    |> unique_constraint(:checkout_request_id)
    |> unique_constraint(:mpesa_receipt_number)
    |> unique_constraint(:transaction_id)
    |> check_constraint(:provider, name: :subscription_payments_provider_valid)
    |> check_constraint(:payment_channel, name: :subscription_payments_channel_valid)
    |> check_constraint(:status, name: :subscription_payments_status_valid)
    |> check_constraint(:currency, name: :subscription_payments_currency_valid)
    |> check_constraint(:amount_kes, name: :subscription_payments_amount_non_negative)
  end
end
