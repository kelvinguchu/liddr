defmodule Liddr.Rides.WomenOnly do
  @moduledoc false

  alias Liddr.Accounts.User
  alias Liddr.Rides.VehicleCategory

  @women_only_slug "women_only"
  @female "female"

  def ensure_rider_eligible(%User{} = rider, %VehicleCategory{slug: @women_only_slug}) do
    if rider.gender == @female, do: :ok, else: {:error, :women_only_rider_not_eligible}
  end

  def ensure_rider_eligible(%User{}, %VehicleCategory{}), do: :ok
end
