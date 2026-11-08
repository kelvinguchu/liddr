defmodule Liddr.Rides.CandidateSelectionWomenOnlyTest do
  use Liddr.DataCase, async: false

  alias Decimal, as: D
  alias Liddr.Repo
  alias Liddr.Rides.CandidateSelection
  alias Liddr.Rides.VehicleCategory
  alias Liddr.VerificationFixtures

  test "women_only category returns only female and gender-verified drivers" do
    category_id =
      VerificationFixtures.insert_vehicle_category!(%{slug: "women_only", label: "Women Only"})

    pickup = %{lat: -1.2921, lng: 36.8219}

    eligible_driver_id =
      create_driver!(category_id,
        gender: "female",
        gender_verified: true,
        lat: "-1.2921000",
        lng: "36.8219000"
      )

    _unverified_driver_id =
      create_driver!(category_id,
        gender: "female",
        gender_verified: false,
        lat: "-1.2921500",
        lng: "36.8219500"
      )

    _male_driver_id =
      create_driver!(category_id,
        gender: "male",
        gender_verified: true,
        lat: "-1.2922000",
        lng: "36.8220000"
      )

    assert [driver_id] =
             CandidateSelection.list_eligible_driver_ids(category(category_id), pickup, 3)

    assert driver_id == eligible_driver_id
  end

  defp create_driver!(category_id, opts) do
    user =
      VerificationFixtures.create_user!(%{
        phone: VerificationFixtures.unique_phone(),
        gender: opts[:gender]
      })

    driver =
      VerificationFixtures.create_driver!(
        user: user,
        vehicle_category_id: category_id,
        account_status: "active",
        verification_status: "approved",
        subscription_status: "active",
        is_available: true,
        gender_verified: opts[:gender_verified]
      )

    _ =
      VerificationFixtures.create_driver_location!(driver.user_id,
        lat: D.new(opts[:lat]),
        lng: D.new(opts[:lng])
      )

    driver.user_id
  end

  defp category(category_id), do: Repo.get!(VehicleCategory, category_id)
end
