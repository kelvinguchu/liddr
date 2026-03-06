defmodule Liddr.Subscriptions.WebhookEvents do
  import Ecto.Query

  alias Liddr.Repo
  alias Liddr.Subscriptions.WebhookEvent
  alias Liddr.Payments.Mpesa.Sanitizer

  def get_or_create!(event_type, external_ref, payload) do
    existing =
      Repo.one(
        from e in WebhookEvent,
          where:
            e.provider == "mpesa" and e.event_type == ^event_type and
              e.external_ref == ^external_ref,
          lock: "FOR UPDATE"
      )

    if existing do
      existing
    else
      %WebhookEvent{}
      |> WebhookEvent.create_changeset(%{
        "provider" => "mpesa",
        "event_type" => event_type,
        "external_ref" => external_ref,
        "payload" => Sanitizer.payload(payload)
      })
      |> Repo.insert()
      |> case do
        {:ok, value} ->
          value

        {:error, %Ecto.Changeset{} = changeset} ->
          if unique_constraint_error?(changeset, :external_ref) do
            Repo.one(
              from e in WebhookEvent,
                where:
                  e.provider == "mpesa" and e.event_type == ^event_type and
                    e.external_ref == ^external_ref,
                lock: "FOR UPDATE"
            ) || Repo.rollback(changeset)
          else
            Repo.rollback(changeset)
          end

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end
  end

  def mark_processed!(event, now) do
    event
    |> Ecto.Changeset.change(%{processed_at: now, processing_error: nil})
    |> Repo.update()
    |> case do
      {:ok, _value} -> :ok
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp unique_constraint_error?(changeset, field) do
    Enum.any?(changeset.errors, fn {key, {_message, opts}} ->
      key == field and opts[:constraint] == :unique
    end)
  end
end
