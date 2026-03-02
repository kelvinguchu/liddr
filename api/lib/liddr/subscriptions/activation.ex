defmodule Liddr.Subscriptions.Activation do
  import Ecto.Query

  alias Liddr.Accounts.Driver
  alias Liddr.Repo
  alias Liddr.Subscriptions.Subscription
  alias Liddr.Verification.DriverActivityEvent

  def activate_subscription!(payment, now) do
    subscription =
      Repo.one(
        from s in Subscription,
          where: s.id == ^payment.subscription_id,
          lock: "FOR UPDATE"
      ) || Repo.rollback(:subscription_not_found)

    _updated_subscription =
      subscription
      |> Subscription.create_changeset(%{
        "status" => "active",
        "activated_at" => subscription.activated_at || now
      })
      |> Repo.update()
      |> case do
        {:ok, value} -> value
        {:error, changeset} -> Repo.rollback(changeset)
      end

    driver = Repo.get(Driver, payment.driver_id) || Repo.rollback(:driver_profile_not_found)
    previous_status = driver.subscription_status

    updated_driver =
      driver
      |> Driver.create_changeset(%{
        "subscription_status" => "active",
        "last_seen_at" => now
      })
      |> Repo.update()
      |> case do
        {:ok, value} -> value
        {:error, changeset} -> Repo.rollback(changeset)
      end

    if previous_status != updated_driver.subscription_status do
      %DriverActivityEvent{}
      |> DriverActivityEvent.create_changeset(%{
        "driver_id" => driver.user_id,
        "event_type" => "subscription_updated",
        "previous_value" => previous_status,
        "new_value" => updated_driver.subscription_status,
        "reason_code" => "subscription_payment_success",
        "actor_type" => "system",
        "payload" => %{
          "subscription_id" => payment.subscription_id,
          "payment_id" => payment.id
        }
      })
      |> Repo.insert()
      |> case do
        {:ok, _event} -> :ok
        {:error, changeset} -> Repo.rollback(changeset)
      end
    else
      :ok
    end
  end
end
