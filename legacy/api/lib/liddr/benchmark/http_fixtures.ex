defmodule Liddr.Benchmark.HttpFixtures do
  @moduledoc false

  import Ecto.Query

  alias Decimal, as: D
  alias Liddr.Accounts.Driver
  alias Liddr.Accounts.User
  alias Liddr.Accounts.UserRole
  alias Liddr.Auth.AuthSession
  alias Liddr.Auth.Sessions
  alias Liddr.Idempotency.Request, as: IdempotencyRequest
  alias Liddr.Location
  alias Liddr.Location.DriverLocation
  alias Liddr.Ratings.Rating
  alias Liddr.Ratings.RatingAction
  alias Liddr.Repo
  alias Liddr.Rides.Ride
  alias Liddr.Rides.RideDestinationChange
  alias Liddr.Rides.RideEvent
  alias Liddr.Rides.RideMessage
  alias Liddr.Rides.RideNotification
  alias Liddr.Rides.RideOffer
  alias Liddr.Rides.RideQuote
  alias Liddr.Rides.SendDelivery
  alias Liddr.Rides.SharedRideGroup
  alias Liddr.Rides.SharedRideMember
  alias Liddr.Rides.SharedRideStop
  alias Liddr.Rides.UserPushToken
  alias Liddr.Rides.VehicleCategory

  @pickup %{lat: "-1.2921000", lng: "36.8219000"}
  @dropoff %{lat: "-1.3000000", lng: "36.8000000"}

  def prepare_state(config) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    category = active_category!()

    %{
      category: category,
      riders: create_riders(config.rider_pool_size, category.id, now),
      drivers: create_drivers(config.driver_pool_size, category.id, now)
    }
  end

  def cleanup_state(%{riders: riders, drivers: drivers}) do
    driver_ids = Enum.map(drivers, & &1.user_id)
    rider_ids = Enum.map(riders, & &1.user_id)
    user_ids = rider_ids ++ driver_ids

    Enum.each(driver_ids, &Location.remove_driver_from_supply/1)

    Repo.transaction(fn ->
      ride_ids = ride_ids_for_users(rider_ids, driver_ids)
      rating_ids = rating_ids_for_cleanup(ride_ids, user_ids)
      group_ids = group_ids_for_rides(ride_ids)

      delete_by_ids(SharedRideStop, :group_id, group_ids)
      delete_by_ids(SharedRideStop, :ride_id, ride_ids)
      delete_by_ids(SharedRideMember, :group_id, group_ids)
      delete_by_ids(SharedRideMember, :ride_id, ride_ids)
      delete_by_ids(SharedRideGroup, :ride_id, ride_ids)
      delete_by_ids(SendDelivery, :ride_id, ride_ids)
      delete_by_ids(RideDestinationChange, :ride_id, ride_ids)
      delete_by_ids(RideMessage, :ride_id, ride_ids)
      delete_by_ids(RideMessage, :sender_user_id, user_ids)
      delete_by_ids(RideMessage, :recipient_user_id, user_ids)
      delete_by_ids(RideNotification, :ride_id, ride_ids)
      delete_by_ids(RideNotification, :recipient_user_id, user_ids)
      delete_by_ids(RatingAction, :rating_id, rating_ids)
      delete_by_ids(RatingAction, :ride_id, ride_ids)
      delete_by_ids(Rating, :ride_id, ride_ids)
      delete_by_ids(RideEvent, :ride_id, ride_ids)
      delete_by_ids(RideOffer, :ride_id, ride_ids)
      delete_by_ids(RideOffer, :driver_id, driver_ids)
      delete_by_ids(Ride, :id, ride_ids)
      delete_by_ids(RideQuote, :rider_id, rider_ids)
      delete_by_ids(IdempotencyRequest, :user_id, user_ids)
      delete_by_ids(AuthSession, :user_id, user_ids)
      delete_by_ids(UserPushToken, :user_id, user_ids)
      delete_by_ids(UserRole, :user_id, user_ids)
      delete_by_ids(DriverLocation, :driver_id, driver_ids)
      delete_by_ids(Driver, :user_id, driver_ids)
      delete_by_ids(User, :id, user_ids)
    end)

    :ok
  end

  def cleanup_state(_state), do: :ok

  defp create_riders(count, category_id, now) do
    Enum.map(1..count, fn _ ->
      user = insert_user!(%{phone: unique_phone(), phone_verified_at: now})
      insert_role!(user.id, "rider", now)
      quote = insert_quote!(user.id, category_id, now)

      %{
        user_id: user.id,
        access_token: issue_access_token(user.id, "phone_otp", now),
        quote_id: quote.id
      }
    end)
  end

  defp create_drivers(count, category_id, now) do
    Enum.map(1..count, fn index ->
      user = insert_user!(%{phone: unique_phone(), phone_verified_at: now})
      insert_role!(user.id, "driver", now)
      insert_driver!(user.id, category_id, now)
      lat = -1.2921 + index * 0.0002
      lng = 36.8219 + index * 0.0002
      {:ok, _} = Location.upsert_driver_location(user.id, %{"lat" => lat, "lng" => lng})

      %{
        user_id: user.id,
        access_token: issue_access_token(user.id, "phone_otp", now),
        lat: lat,
        lng: lng
      }
    end)
  end

  defp active_category! do
    Repo.one(
      from c in VehicleCategory, where: c.is_active == true, order_by: [asc: c.id], limit: 1
    ) || raise "no active vehicle category found"
  end

  defp insert_user!(attrs) do
    %User{} |> User.registration_changeset(attrs) |> Repo.insert!()
  end

  defp insert_role!(user_id, role, now) do
    %UserRole{}
    |> UserRole.create_changeset(%{user_id: user_id, role: role, granted_at: now})
    |> Repo.insert!()
  end

  defp insert_driver!(user_id, category_id, now) do
    %Driver{}
    |> Driver.create_changeset(%{
      user_id: user_id,
      vehicle_category_id: category_id,
      subscription_status: "active",
      is_available: true,
      gender_verified: true,
      account_status: "active",
      verification_status: "approved",
      dispatch_status: "idle",
      last_seen_at: now,
      last_online_at: now,
      activated_at: now
    })
    |> Repo.insert!()
  end

  defp insert_quote!(rider_id, category_id, now) do
    %RideQuote{}
    |> RideQuote.create_changeset(%{
      rider_id: rider_id,
      vehicle_category_id: category_id,
      pickup_lat: D.new(@pickup.lat),
      pickup_lng: D.new(@pickup.lng),
      dropoff_lat: D.new(@dropoff.lat),
      dropoff_lng: D.new(@dropoff.lng),
      distance_m: 2340,
      duration_s: 620,
      static_duration_s: 560,
      base_amount_kes: D.new("20.00"),
      distance_amount_kes: D.new("40.00"),
      time_amount_kes: D.new("10.00"),
      min_fare_kes: D.new("100.00"),
      surge_multiplier: D.new("1.00"),
      subtotal_kes: D.new("100.00"),
      base_fare_kes: D.new("100.00"),
      discount_percent: D.new("0.00"),
      discount_amount_kes: D.new("0.00"),
      final_fare_kes: D.new("100.00"),
      currency: "KES",
      provider: "benchmark",
      expires_at: DateTime.add(now, 3600, :second)
    })
    |> Repo.insert!()
  end

  defp issue_access_token(user_id, auth_method, now) do
    Sessions.issue_session!(user_id, auth_method, now, %{}).access_token
  end

  defp ride_ids_for_users([], []), do: []

  defp ride_ids_for_users(rider_ids, driver_ids) do
    from(r in Ride,
      where: r.rider_id in ^rider_ids or r.driver_id in ^driver_ids,
      select: r.id
    )
    |> Repo.all()
  end

  defp rating_ids_for_cleanup([], []), do: []

  defp rating_ids_for_cleanup(ride_ids, user_ids) do
    from(r in Rating,
      where:
        r.ride_id in ^ride_ids or r.rated_by_user_id in ^user_ids or r.rated_user_id in ^user_ids,
      select: r.id
    )
    |> Repo.all()
  end

  defp group_ids_for_rides([]), do: []

  defp group_ids_for_rides(ride_ids) do
    from(g in SharedRideGroup, where: g.ride_id in ^ride_ids, select: g.id)
    |> Repo.all()
  end

  defp delete_by_ids(_schema, _field, []), do: 0

  defp delete_by_ids(schema, field, ids) do
    from(row in schema, where: field(row, ^field) in ^ids)
    |> Repo.delete_all()
    |> elem(0)
  end

  defp unique_phone do
    suffix =
      :crypto.strong_rand_bytes(4)
      |> :binary.decode_unsigned()
      |> rem(100_000_000)
      |> Integer.to_string()
      |> String.pad_leading(8, "0")

    "07" <> suffix
  end
end
