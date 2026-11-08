defmodule Liddr.Rides.Execution.Completion do
  import Ecto.Query

  alias Decimal, as: D
  alias Liddr.Location
  alias Liddr.Repo
  alias Liddr.Ratings
  alias Liddr.Rides.Dispatcher
  alias Liddr.Rides.Events
  alias Liddr.Rides.Execution.Geofence
  alias Liddr.Rides.Execution.Shared
  alias Liddr.Rides.Realtime
  alias Liddr.Rides.RideQuote
  alias Liddr.Rides.SendDeliveries
  alias Liddr.Rides.SharedRideMember
  alias Liddr.Subscriptions.PaymentUtils

  @payment_modes ~w(cash_direct mpesa_direct in_app_mpesa)
  @unbilled_member_statuses ~w(cancelled no_show)

  def complete_ride(driver_user_id, ride_id, attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    result =
      Repo.transaction(fn ->
        ride = Shared.fetch_ride_for_update!(ride_id)
        Shared.ensure_driver_owns_ride!(ride, driver_user_id)
        driver = Shared.fetch_driver_for_update!(driver_user_id)
        Shared.ensure_driver_locked_to_ride!(driver, ride.id)

        cond do
          ride.status == "completed" ->
            %{ride: ride, transition?: false}

          ride.status != "in_progress" ->
            Repo.rollback(:ride_not_completable)

          true ->
            SendDeliveries.ensure_completion_allowed!(ride, now)
            payment_mode = resolve_payment_mode!(attrs)
            ensure_request_payment_mode_policy!(ride, payment_mode)
            {final_fare, pricing_payload} = resolve_completion_pricing!(ride, payment_mode)
            geofence = Geofence.ensure_completion!(ride, driver.user_id, now)

            completed_ride =
              Shared.update_ride!(ride, %{
                "status" => "completed",
                "completed_at" => now,
                "payment_mode" => payment_mode,
                "final_fare_kes" => final_fare,
                "final_pricing_payload" => pricing_payload,
                "completion_distance_m" => geofence.distance_m
              })

            _ =
              Events.record_event(completed_ride.id, "ride_completed", now,
                actor_user_id: driver_user_id,
                payload:
                  %{
                    "payment_mode" => payment_mode,
                    "final_fare_kes" => decimal_to_string(final_fare)
                  }
                  |> Map.merge(geofence.payload)
              )
              |> Shared.unwrap_or_rollback()

            _ = SendDeliveries.mark_completed!(completed_ride)
            rating_actions = Ratings.enqueue_for_completed_ride!(completed_ride, now)

            _ =
              Events.record_event(completed_ride.id, "ride_rating_pending", now,
                payload: %{
                  "due_at" => DateTime.to_iso8601(rating_actions.due_at),
                  "actions_created" => rating_actions.count
                }
              )
              |> Shared.unwrap_or_rollback()

            _ = Shared.unlock_driver!(driver, now)
            %{ride: completed_ride, transition?: true, rating_due_at: rating_actions.due_at}
        end
      end)
      |> Shared.unwrap_transaction_result()

    case result do
      {:ok, %{ride: ride, transition?: true, rating_due_at: rating_due_at}} ->
        _ = Location.sync_driver_supply(driver_user_id)
        Realtime.broadcast_ride_completed(ride)
        Realtime.broadcast_rating_pending(ride, rating_due_at)
        Realtime.broadcast_driver_unlocked(driver_user_id, ride.id)
        Dispatcher.stop(ride.id)
        {:ok, ride}

      {:ok, %{ride: ride}} ->
        {:ok, ride}

      error ->
        error
    end
  end

  defp resolve_payment_mode!(attrs) do
    payment_mode =
      attrs
      |> PaymentUtils.get_value(:payment_mode)
      |> PaymentUtils.normalize_text()

    if payment_mode in @payment_modes,
      do: payment_mode,
      else: Repo.rollback(:invalid_payment_mode)
  end

  defp resolve_completion_pricing!(ride, payment_mode) do
    quote = fetch_quote(ride.quote_id)
    metadata_final_fare = ride.metadata |> quoted_final_from_metadata() |> parse_decimal()
    quoted_final_fare = metadata_final_fare || (quote && quote.final_fare_kes)
    member_total_fare = shared_member_total(ride)

    final_fare =
      member_total_fare || quoted_final_fare || Repo.rollback(:missing_final_fare)

    pricing_payload = %{
      "quote_id" => ride.quote_id,
      "source" => if(member_total_fare, do: "shared_members", else: "quoted"),
      "currency" => "KES",
      "payment_mode" => payment_mode,
      "quoted_final_fare_kes" => decimal_to_string(quoted_final_fare),
      "final_fare_kes" => decimal_to_string(final_fare),
      "quote_pricing" => quote_pricing_payload(quote)
    }

    {final_fare, pricing_payload}
  end

  defp shared_member_total(%{product_type: "shared", id: ride_id}) do
    Repo.one(
      from m in SharedRideMember,
        where: m.ride_id == ^ride_id and m.status not in ^@unbilled_member_statuses,
        select: sum(m.fare_kes)
    )
  end

  defp shared_member_total(_ride), do: nil

  defp quote_pricing_payload(nil), do: %{}

  defp quote_pricing_payload(quote) do
    %{
      "distance_m" => quote.distance_m,
      "duration_s" => quote.duration_s,
      "base_fare_kes" => decimal_to_string(quote.base_fare_kes),
      "discount_percent" => decimal_to_string(quote.discount_percent),
      "discount_amount_kes" => decimal_to_string(quote.discount_amount_kes),
      "final_fare_kes" => decimal_to_string(quote.final_fare_kes)
    }
  end

  defp fetch_quote(nil), do: nil
  defp fetch_quote(quote_id), do: Repo.get(RideQuote, quote_id)

  defp quoted_final_from_metadata(metadata) when is_map(metadata) do
    Map.get(metadata, "quoted_final_fare_kes") || Map.get(metadata, :quoted_final_fare_kes)
  end

  defp quoted_final_from_metadata(_metadata), do: nil

  defp ensure_request_payment_mode_policy!(ride, payment_mode) do
    required_payment_mode =
      ride.metadata
      |> requested_payment_mode_from_metadata()
      |> PaymentUtils.normalize_text()

    if is_nil(required_payment_mode) or required_payment_mode == payment_mode do
      :ok
    else
      Repo.rollback(:payment_mode_mismatch_for_policy)
    end
  end

  defp requested_payment_mode_from_metadata(%{} = metadata) do
    Map.get(metadata, "requested_payment_mode") || Map.get(metadata, :requested_payment_mode)
  end

  defp requested_payment_mode_from_metadata(_metadata), do: nil

  defp parse_decimal(nil), do: nil
  defp parse_decimal(%D{} = value), do: value
  defp parse_decimal(value) when is_integer(value), do: D.new(value)
  defp parse_decimal(value) when is_float(value), do: value |> D.from_float() |> D.round(2)

  defp parse_decimal(value) when is_binary(value) do
    case D.parse(String.trim(value)) do
      {decimal, ""} -> if finite_decimal?(decimal), do: decimal
      _ -> nil
    end
  end

  defp parse_decimal(_value), do: nil

  defp finite_decimal?(decimal), do: not (D.nan?(decimal) or D.inf?(decimal))

  defp decimal_to_string(nil), do: nil
  defp decimal_to_string(%D{} = value), do: D.to_string(value, :normal)
  defp decimal_to_string(value), do: to_string(value)
end
