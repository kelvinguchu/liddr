defmodule Liddr.Rides.Lifecycle.ListOffers do
  import Ecto.Query

  alias Liddr.Accounts.Driver
  alias Liddr.Repo
  alias Liddr.Rides.DriverOfferLock
  alias Liddr.Rides.Events
  alias Liddr.Rides.Ride
  alias Liddr.Rides.RideOffer
  alias Liddr.Subscriptions.PaymentUtils

  def list_driver_offers(driver_user_id, attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    limit = resolve_history_limit(attrs)

    _ = maybe_expire_offers!(driver_user_id, now)

    offers =
      Repo.all(
        from o in RideOffer,
          join: r in Ride,
          on: r.id == o.ride_id,
          join: d in Driver,
          on: d.user_id == o.driver_id,
          where:
            o.driver_id == ^driver_user_id and o.status == "offered" and o.expires_at > ^now and
              is_nil(d.current_ride_id),
          order_by: [desc: o.inserted_at],
          limit: ^limit,
          select: %{offer: o, ride: r}
      )

    {:ok, offers}
  end

  defp maybe_expire_offers!(driver_user_id, now) do
    expired_offers =
      Repo.all(
        from o in RideOffer,
          where: o.driver_id == ^driver_user_id and o.status == "offered" and o.expires_at <= ^now
      )

    if expired_offers != [] do
      _ =
        Repo.update_all(
          from(o in RideOffer,
            where:
              o.driver_id == ^driver_user_id and o.status == "offered" and o.expires_at <= ^now
          ),
          set: [status: "expired", responded_at: now, updated_at: now]
        )

      record_offer_events!("offer_expired", expired_offers, now)
      record_offer_events!("offer_missed", expired_offers, now)
      DriverOfferLock.release_many(expired_offers, source: "driver_offer_list_expire")
    end

    :ok
  end

  defp resolve_history_limit(attrs) do
    attrs
    |> PaymentUtils.get_value(:limit)
    |> parse_positive_integer()
    |> clamp(20, 100)
  end

  defp clamp(nil, default, _max), do: default
  defp clamp(value, _default, max) when value > max, do: max
  defp clamp(value, _default, _max), do: value

  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: value

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp parse_positive_integer(_value), do: nil

  defp record_offer_events!(_event_type, [], _occurred_at), do: :ok

  defp record_offer_events!(event_type, offers, occurred_at) do
    Enum.each(offers, fn offer ->
      payload = %{"offer_id" => offer.id, "driver_id" => offer.driver_id}

      _ =
        Events.record_event(offer.ride_id, event_type, occurred_at,
          actor_user_id: offer.driver_id,
          payload: payload
        )
        |> unwrap_or_rollback()
    end)
  end

  defp unwrap_or_rollback({:ok, value}), do: value
  defp unwrap_or_rollback({:error, changeset}), do: Repo.rollback(changeset)
end
