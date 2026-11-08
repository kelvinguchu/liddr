defmodule Liddr.Rides.Lifecycle.OfferActionsSupport do
  import Ecto.Query

  alias Ecto.Changeset
  alias Liddr.Accounts.Driver
  alias Liddr.Accounts.User
  alias Liddr.Auth.Policy
  alias Liddr.Repo
  alias Liddr.Rides.ActiveRides
  alias Liddr.Rides.DriverLiveness
  alias Liddr.Rides.Events
  alias Liddr.Rides.Realtime
  alias Liddr.Rides.Ride
  alias Liddr.Rides.RideOffer

  @assignable_ride_statuses ~w(requested offering)

  def fetch_offer_for_update!(offer_id) do
    parsed_offer_id = parse_positive_integer(offer_id) || Repo.rollback(:ride_offer_not_found)

    Repo.one(
      from o in RideOffer,
        where: o.id == ^parsed_offer_id,
        lock: "FOR UPDATE"
    ) || Repo.rollback(:ride_offer_not_found)
  end

  def fetch_ride_for_update!(ride_id) do
    Repo.one(
      from r in Ride,
        where: r.id == ^ride_id,
        lock: "FOR UPDATE"
    ) || Repo.rollback(:ride_not_found)
  end

  def ensure_offer_belongs_to_driver!(offer, driver_user_id) do
    if offer.driver_id == driver_user_id, do: :ok, else: Repo.rollback(:offer_not_for_driver)
  end

  def ensure_offer_open!(offer, now) do
    cond do
      offer.status != "offered" ->
        Repo.rollback(:ride_offer_not_open)

      DateTime.compare(offer.expires_at, now) != :gt ->
        _ =
          offer
          |> RideOffer.create_changeset(%{"status" => "expired", "responded_at" => now})
          |> Repo.update()

        Repo.rollback(:ride_offer_expired)

      true ->
        :ok
    end
  end

  def ensure_ride_assignable!(ride) do
    if ride.status in @assignable_ride_statuses and is_nil(ride.driver_id) do
      :ok
    else
      Repo.rollback(:ride_not_assignable)
    end
  end

  def ensure_driver_eligible_for_accept!(driver_user_id, now) do
    user = Repo.get(User, driver_user_id) || Repo.rollback(:user_not_found)

    case Policy.ensure_user_can_authenticate(user) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end

    driver =
      Repo.one(
        from d in Driver,
          where: d.user_id == ^driver_user_id,
          lock: "FOR UPDATE"
      ) || Repo.rollback(:driver_profile_not_found)

    cond do
      driver.account_status != "active" ->
        Repo.rollback(:driver_account_not_active)

      driver.verification_status != "approved" ->
        Repo.rollback(:driver_not_verified)

      driver.subscription_status != "active" ->
        Repo.rollback(:driver_subscription_not_active)

      not is_nil(driver.current_ride_id) ->
        Repo.rollback(:driver_has_active_ride)

      ActiveRides.driver_has_active_ride?(driver_user_id) ->
        Repo.rollback(:driver_has_active_ride)

      driver.is_available != true ->
        Repo.rollback(:driver_not_available)

      not DriverLiveness.accept_allowed?(DriverLiveness.snapshot(driver, now)) ->
        Repo.rollback(:driver_presence_unhealthy)

      true ->
        driver
    end
  end

  def normalize_ride_metadata(%{} = metadata), do: metadata
  def normalize_ride_metadata(_metadata), do: %{}

  def unwrap_transaction_result({:ok, payload}), do: {:ok, payload}
  def unwrap_transaction_result({:error, reason}), do: {:error, reason}
  def unwrap_or_rollback({:ok, value}), do: value
  def unwrap_or_rollback({:error, changeset}), do: Repo.rollback(changeset)

  def normalize_accept_error({:error, %Changeset{} = changeset}) do
    if active_driver_conflict_changeset?(changeset),
      do: {:error, :driver_has_active_ride},
      else: {:error, changeset}
  end

  def normalize_accept_error(result), do: result

  def build_new_driver_found_payload(%{} = metadata, new_driver_id, offer_id) do
    reassign_count = Map.get(metadata, "reassign_count", 0)

    if is_integer(reassign_count) and reassign_count > 0 do
      %{
        "reassign_count" => reassign_count,
        "previous_driver_id" => Map.get(metadata, "last_reassign_driver_id"),
        "new_driver_id" => new_driver_id,
        "offer_id" => offer_id,
        "recommendation_reason_code" => Map.get(metadata, "last_reassign_reason_code")
      }
    else
      nil
    end
  end

  def build_new_driver_found_payload(_metadata, _new_driver_id, _offer_id), do: nil

  def maybe_record_new_driver_found_event(_ride_id, _driver_user_id, nil, _now), do: {:ok, nil}

  def maybe_record_new_driver_found_event(ride_id, driver_user_id, payload, now) do
    Events.record_event(ride_id, "new_driver_found", now,
      actor_user_id: driver_user_id,
      payload: payload
    )
  end

  def maybe_broadcast_new_driver_found(_ride, nil), do: :ok

  def maybe_broadcast_new_driver_found(ride, payload) do
    Realtime.broadcast_new_driver_found(ride, %{
      previous_driver_id: payload["previous_driver_id"],
      new_driver_id: payload["new_driver_id"],
      reassign_count: payload["reassign_count"],
      recommendation_reason_code: payload["recommendation_reason_code"],
      offer_id: payload["offer_id"]
    })
  end

  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: value

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp parse_positive_integer(_value), do: nil

  defp active_driver_conflict_changeset?(changeset) do
    changeset.errors
    |> Keyword.get_values(:driver_id)
    |> Enum.any?(fn {_message, opts} ->
      Keyword.get(opts, :constraint) == :unique and
        Keyword.get(opts, :constraint_name) == "rides_unique_active_driver_idx"
    end)
  end
end
