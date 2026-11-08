defmodule Liddr.Subscriptions.Activation do
  import Ecto.Query

  alias Liddr.Accounts.Driver
  alias Liddr.Location.DriverHotState
  alias Liddr.Repo
  alias Liddr.Subscriptions.PaymentUtils
  alias Liddr.Subscriptions.Subscription
  alias Liddr.Verification.DriverActivityEvent

  def activate_subscription!(payment, now) do
    paid_subscription =
      Repo.one(
        from(s in Subscription,
          where: s.id == ^payment.subscription_id,
          lock: "FOR UPDATE"
        )
      ) || Repo.rollback(:subscription_not_found)

    subscription = subscription_to_activate!(paid_subscription, payment)

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

    :ok = DriverHotState.put(updated_driver)

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

  defp subscription_to_activate!(paid_subscription, payment) do
    {week_start, week_end} = PaymentUtils.current_week_range(Date.utc_today())

    if Date.compare(paid_subscription.week_end, week_start) == :lt do
      subscription = current_week_subscription!(paid_subscription, week_start, week_end)
      move_payment_to_subscription!(payment, subscription)
      subscription
    else
      paid_subscription
    end
  end

  defp current_week_subscription!(paid_subscription, week_start, week_end) do
    Repo.one(
      from(s in Subscription,
        where:
          s.driver_id == ^paid_subscription.driver_id and s.week_start == ^week_start and
            s.week_end == ^week_end,
        lock: "FOR UPDATE"
      )
    ) || insert_current_week_subscription!(paid_subscription, week_start, week_end)
  end

  defp insert_current_week_subscription!(paid_subscription, week_start, week_end) do
    %Subscription{}
    |> Subscription.create_changeset(%{
      "driver_id" => paid_subscription.driver_id,
      "vehicle_category_id" => paid_subscription.vehicle_category_id,
      "week_start" => week_start,
      "week_end" => week_end,
      "amount_kes" => paid_subscription.amount_kes,
      "status" => "pending"
    })
    |> Repo.insert()
    |> case do
      {:ok, value} -> value
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp move_payment_to_subscription!(payment, subscription) do
    payment
    |> Ecto.Changeset.change(subscription_id: subscription.id)
    |> Repo.update()
    |> case do
      {:ok, value} -> value
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end
end
