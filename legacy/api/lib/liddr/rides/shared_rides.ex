defmodule Liddr.Rides.SharedRides do
  @moduledoc false

  alias Liddr.Rides.SharedRides.Context
  alias Liddr.Rides.SharedRides.MemberActions
  alias Liddr.Rides.SharedRides.MemberProgress

  def context_for_user(user_id, ride_id), do: Context.for_user(user_id, ride_id)

  def rider_cancel_member(rider_user_id, ride_id, member_id, attrs \\ %{}) do
    MemberActions.rider_cancel_member(rider_user_id, ride_id, member_id, attrs)
  end

  def driver_mark_member_no_show(driver_user_id, ride_id, member_id, attrs \\ %{}) do
    MemberActions.driver_mark_member_no_show(driver_user_id, ride_id, member_id, attrs)
  end

  def driver_arrive_member_pickup(driver_user_id, ride_id, member_id) do
    MemberProgress.driver_arrive_member_pickup(driver_user_id, ride_id, member_id)
  end

  def driver_mark_member_picked_up(driver_user_id, ride_id, member_id) do
    MemberProgress.driver_mark_member_picked_up(driver_user_id, ride_id, member_id)
  end

  def driver_mark_member_dropped_off(driver_user_id, ride_id, member_id) do
    MemberProgress.driver_mark_member_dropped_off(driver_user_id, ride_id, member_id)
  end
end
