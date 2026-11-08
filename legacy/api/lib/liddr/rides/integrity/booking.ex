defmodule Liddr.Rides.Integrity.Booking do
  @moduledoc false

  import Ecto.Query

  alias Liddr.Accounts.User
  alias Liddr.Auth.Policy, as: AuthPolicy
  alias Liddr.Repo
  alias Liddr.Rides.Integrity.Policy
  alias Liddr.Subscriptions.PaymentUtils

  def fetch_rider_for_request!(rider_user_id, now) do
    rider =
      Repo.one(from u in User, where: u.id == ^rider_user_id, lock: "FOR UPDATE") ||
        Repo.rollback(:rider_not_found)

    case AuthPolicy.ensure_user_can_authenticate(rider) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end

    maybe_release_expired_prepay!(rider, now)
  end

  def ensure_request_allowed!(%User{} = rider, attrs, now) do
    requested_payment_mode =
      attrs
      |> PaymentUtils.get_value(:payment_mode)
      |> PaymentUtils.normalize_text()

    if prepay_only_active?(rider, now) and
         requested_payment_mode != Policy.rider_prepay_payment_mode() do
      Repo.rollback(
        {:rider_prepay_required,
         %{
           "required_payment_mode" => Policy.rider_prepay_payment_mode(),
           "ride_booking_mode_until" => rider.ride_booking_mode_until
         }}
      )
    end

    requested_payment_mode
  end

  defp prepay_only_active?(%User{} = user, now) do
    user.ride_booking_mode == "prepay_only" and
      is_struct(user.ride_booking_mode_until, DateTime) and
      DateTime.compare(user.ride_booking_mode_until, now) == :gt
  end

  defp maybe_release_expired_prepay!(%User{} = user, now) do
    cond do
      user.ride_booking_mode != "prepay_only" ->
        user

      is_nil(user.ride_booking_mode_until) ->
        user

      DateTime.compare(user.ride_booking_mode_until, now) == :gt ->
        user

      true ->
        user
        |> User.ride_booking_mode_changeset(%{
          "ride_booking_mode" => "normal",
          "ride_booking_mode_until" => nil
        })
        |> Repo.update()
        |> unwrap_or_rollback()
    end
  end

  defp unwrap_or_rollback({:ok, value}), do: value
  defp unwrap_or_rollback({:error, changeset}), do: Repo.rollback(changeset)
end
