defmodule Liddr.Subscriptions.WebhookEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @providers ~w(mpesa)
  @event_types ~w(stk_callback c2b_callback tx_status_callback)

  schema "webhook_events" do
    field :provider, :string
    field :event_type, :string
    field :external_ref, :string
    field :payload, :map, default: %{}
    field :processed_at, :utc_datetime_usec
    field :processing_error, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def create_changeset(event, attrs) do
    event
    |> cast(attrs, [
      :provider,
      :event_type,
      :external_ref,
      :payload,
      :processed_at,
      :processing_error
    ])
    |> validate_required([:provider, :event_type, :external_ref, :payload])
    |> validate_inclusion(:provider, @providers)
    |> validate_inclusion(:event_type, @event_types)
    |> unique_constraint(:external_ref,
      name: :webhook_events_provider_event_type_external_ref_index
    )
    |> check_constraint(:provider, name: :webhook_events_provider_valid)
    |> check_constraint(:event_type, name: :webhook_events_type_valid)
  end
end
