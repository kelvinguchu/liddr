defmodule Liddr.Subscriptions.Lookup do
  import Ecto.Query

  alias Liddr.Accounts.Driver
  alias Liddr.Repo
  alias Liddr.Subscriptions.Subscription
  alias Liddr.Subscriptions.SubscriptionPayment

  def current_subscription(driver_user_id) do
    with %Driver{} = driver <- Repo.get(Driver, driver_user_id) do
      subscription =
        Repo.one(
          from s in Subscription,
            where: s.driver_id == ^driver_user_id,
            order_by: [desc: s.week_end, desc: s.id],
            limit: 1
        )

      latest_payment =
        if subscription do
          Repo.one(
            from p in SubscriptionPayment,
              where: p.subscription_id == ^subscription.id,
              order_by: [desc: p.inserted_at, desc: p.id],
              limit: 1
          )
        end

      {:ok, %{driver: driver, subscription: subscription, latest_payment: latest_payment}}
    else
      nil ->
        {:error, :driver_profile_not_found}
    end
  end

  def list_payment_history(driver_user_id, attrs \\ %{}) do
    with %Driver{} <- Repo.get(Driver, driver_user_id) do
      per_page = parse_integer(get_value(attrs, :per_page), 20, 1, 200)
      page = parse_integer(get_value(attrs, :page), 1, 1, 10_000)

      payments =
        from(p in SubscriptionPayment,
          where: p.driver_id == ^driver_user_id,
          preload: [:subscription],
          order_by: [desc: p.requested_at, desc: p.id],
          limit: ^per_page,
          offset: ^((page - 1) * per_page)
        )
        |> Repo.all()

      {:ok, payments}
    else
      nil ->
        {:error, :driver_profile_not_found}
    end
  end

  def ops_lookup_driver(driver_user_id, attrs \\ %{}) do
    with %Driver{} = driver <- Repo.get(Driver, driver_user_id) do
      per_page = parse_integer(get_value(attrs, :per_page), 20, 1, 200)

      subscription =
        Repo.one(
          from s in Subscription,
            where: s.driver_id == ^driver_user_id,
            order_by: [desc: s.week_end, desc: s.id],
            limit: 1
        )

      payments =
        from(p in SubscriptionPayment,
          where: p.driver_id == ^driver_user_id,
          preload: [:subscription],
          order_by: [desc: p.requested_at, desc: p.id],
          limit: ^per_page
        )
        |> Repo.all()

      {:ok, %{driver: driver, subscription: subscription, payments: payments}}
    else
      nil ->
        {:error, :driver_profile_not_found}
    end
  end

  def ops_lookup_payment_by_checkout(checkout_request_id) do
    case normalize_text(checkout_request_id) do
      nil ->
        {:error, :invalid_checkout_request_id}

      normalized_checkout_request_id ->
        payment =
          Repo.one(
            from p in SubscriptionPayment,
              where: p.checkout_request_id == ^normalized_checkout_request_id,
              preload: [:subscription],
              order_by: [desc: p.requested_at, desc: p.id],
              limit: 1
          )

        if payment, do: {:ok, payment}, else: {:error, :subscription_payment_not_found}
    end
  end

  defp get_value(attrs, key) when is_map(attrs),
    do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  defp get_value(_attrs, _key), do: nil

  defp normalize_text(nil), do: nil

  defp normalize_text(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      parsed -> parsed
    end
  end

  defp normalize_text(value), do: value |> to_string() |> normalize_text()

  defp parse_integer(value, default, min, max) do
    parsed =
      case value do
        int when is_integer(int) -> int
        binary when is_binary(binary) -> parse_integer(binary, default)
        _ -> default
      end

    if parsed < min or parsed > max, do: default, else: parsed
  end

  defp parse_integer(nil, default), do: default

  defp parse_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end

  defp parse_integer(value, _default) when is_integer(value), do: value
  defp parse_integer(_value, default), do: default
end
