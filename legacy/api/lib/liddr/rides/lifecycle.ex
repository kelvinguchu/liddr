defmodule Liddr.Rides.Lifecycle do
  alias Liddr.Rides.Lifecycle.ListOffers
  alias Liddr.Rides.Lifecycle.OfferActions

  def list_driver_offers(driver_user_id, attrs \\ %{}),
    do: ListOffers.list_driver_offers(driver_user_id, attrs)

  def accept_offer(driver_user_id, offer_id),
    do: OfferActions.accept_offer(driver_user_id, offer_id)

  def reject_offer(driver_user_id, offer_id),
    do: OfferActions.reject_offer(driver_user_id, offer_id)
end
