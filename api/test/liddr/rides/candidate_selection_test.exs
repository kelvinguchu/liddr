defmodule Liddr.Rides.CandidateSelectionTest do
  use Liddr.DataCase, async: false

  import Ecto.Query

  alias Decimal, as: D
  alias Liddr.Accounts.User
  alias Liddr.Repo
  alias Liddr.Rides.CandidateSelection
  alias Liddr.Rides.VehicleCategory
  alias Liddr.TestSupplyIndex
  alias Liddr.VerificationFixtures

  test "rating breaks ties for nearby drivers in the same distance bucket" do
    category_id = VerificationFixtures.insert_vehicle_category!()
    pickup = %{lat: -1.2921, lng: 36.8219}

    low_rating_driver_id =
      create_eligible_driver!(category_id,
        lat: "-1.2921000",
        lng: "36.8219000",
        rating_score: "1.0",
        rating_count: 60
      )

    high_rating_driver_id =
      create_eligible_driver!(category_id,
        lat: "-1.2925500",
        lng: "36.8219000",
        rating_score: "5.0",
        rating_count: 60
      )

    assert [first, second] =
             CandidateSelection.list_eligible_driver_ids(category(category_id), pickup, 2)

    assert first == high_rating_driver_id
    assert second == low_rating_driver_id
  end

  test "distance bucket keeps much closer driver ahead of farther high-rated driver" do
    category_id = VerificationFixtures.insert_vehicle_category!()
    pickup = %{lat: -1.2921, lng: 36.8219}

    near_low_rating_driver_id =
      create_eligible_driver!(category_id,
        lat: "-1.2921000",
        lng: "36.8219000",
        rating_score: "1.0",
        rating_count: 60
      )

    far_high_rating_driver_id =
      create_eligible_driver!(category_id,
        lat: "-1.2959000",
        lng: "36.8219000",
        rating_score: "5.0",
        rating_count: 60
      )

    assert [first, second] =
             CandidateSelection.list_eligible_driver_ids(category(category_id), pickup, 2)

    assert first == near_low_rating_driver_id
    assert second == far_high_rating_driver_id
  end

  test "new driver uses neutral rating score when rating volume is below threshold" do
    category_id = VerificationFixtures.insert_vehicle_category!()
    pickup = %{lat: -1.2921, lng: 36.8219}

    established_low_rating_driver_id =
      create_eligible_driver!(category_id,
        lat: "-1.2921000",
        lng: "36.8219000",
        rating_score: "1.0",
        rating_count: 60
      )

    new_driver_id =
      create_eligible_driver!(category_id,
        lat: "-1.2923500",
        lng: "36.8219000",
        rating_score: nil,
        rating_count: 0
      )

    assert [first, second] =
             CandidateSelection.list_eligible_driver_ids(category(category_id), pickup, 2)

    assert first == new_driver_id
    assert second == established_low_rating_driver_id
  end

  test "supply index prefilter narrows dispatch candidates before ranking" do
    previous_index = Application.get_env(:liddr, :ride_supply_index)
    previous_mode = Application.get_env(:liddr, TestSupplyIndex)

    on_exit(fn ->
      restore_env(:ride_supply_index, previous_index)
      restore_env(TestSupplyIndex, previous_mode)
    end)

    Application.put_env(:liddr, :ride_supply_index, TestSupplyIndex)
    category_id = VerificationFixtures.insert_vehicle_category!()
    pickup = %{lat: -1.2921, lng: 36.8219}

    preferred_driver_id =
      create_eligible_driver!(category_id,
        lat: "-1.2921000",
        lng: "36.8219000",
        rating_score: "3.5",
        rating_count: 60
      )

    _other_driver_id =
      create_eligible_driver!(category_id,
        lat: "-1.2922000",
        lng: "36.8220000",
        rating_score: "5.0",
        rating_count: 60
      )

    Application.put_env(:liddr, TestSupplyIndex, mode: {:ok, [preferred_driver_id]})

    assert [driver_id] =
             CandidateSelection.list_eligible_driver_ids(category(category_id), pickup, 2)

    assert driver_id == preferred_driver_id
  end

  test "candidate selection falls back to DB search when supply index is unavailable" do
    previous_index = Application.get_env(:liddr, :ride_supply_index)
    previous_mode = Application.get_env(:liddr, TestSupplyIndex)

    on_exit(fn ->
      restore_env(:ride_supply_index, previous_index)
      restore_env(TestSupplyIndex, previous_mode)
    end)

    Application.put_env(:liddr, :ride_supply_index, TestSupplyIndex)
    Application.put_env(:liddr, TestSupplyIndex, mode: {:error, :supply_index_unavailable})

    category_id = VerificationFixtures.insert_vehicle_category!()
    pickup = %{lat: -1.2921, lng: 36.8219}

    near_driver_id =
      create_eligible_driver!(category_id,
        lat: "-1.2921000",
        lng: "36.8219000",
        rating_score: "4.5",
        rating_count: 60
      )

    assert [driver_id] =
             CandidateSelection.list_eligible_driver_ids(category(category_id), pickup, 1)

    assert driver_id == near_driver_id
  end

  test "candidate selection falls back to DB search when supply prefilter returns empty ids" do
    previous_index = Application.get_env(:liddr, :ride_supply_index)
    previous_mode = Application.get_env(:liddr, TestSupplyIndex)

    on_exit(fn ->
      restore_env(:ride_supply_index, previous_index)
      restore_env(TestSupplyIndex, previous_mode)
    end)

    Application.put_env(:liddr, :ride_supply_index, TestSupplyIndex)
    Application.put_env(:liddr, TestSupplyIndex, mode: {:ok, []})

    category_id = VerificationFixtures.insert_vehicle_category!()
    pickup = %{lat: -1.2921, lng: 36.8219}

    near_driver_id =
      create_eligible_driver!(category_id,
        lat: "-1.2921000",
        lng: "36.8219000",
        rating_score: "4.5",
        rating_count: 60
      )

    assert [driver_id] =
             CandidateSelection.list_eligible_driver_ids(category(category_id), pickup, 1)

    assert driver_id == near_driver_id
  end

  defp create_eligible_driver!(category_id, opts) do
    user = VerificationFixtures.create_user!()

    update_user_rating!(user.id, opts[:rating_score], opts[:rating_count] || 0)

    driver =
      VerificationFixtures.create_driver!(
        user: user,
        vehicle_category_id: category_id,
        account_status: "active",
        verification_status: "approved",
        subscription_status: "active",
        is_available: true
      )

    _ =
      VerificationFixtures.create_driver_location!(driver.user_id,
        lat: D.new(opts[:lat]),
        lng: D.new(opts[:lng])
      )

    driver.user_id
  end

  defp update_user_rating!(user_id, nil, rating_count) do
    _ =
      Repo.update_all(
        from(u in User, where: u.id == ^user_id),
        set: [rating_score: nil, rating_count: rating_count]
      )

    :ok
  end

  defp update_user_rating!(user_id, rating_score, rating_count) do
    _ =
      Repo.update_all(
        from(u in User, where: u.id == ^user_id),
        set: [rating_score: D.new(rating_score), rating_count: rating_count]
      )

    :ok
  end

  defp category(category_id), do: Repo.get!(VehicleCategory, category_id)

  defp restore_env(key, nil), do: Application.delete_env(:liddr, key)
  defp restore_env(key, value), do: Application.put_env(:liddr, key, value)
end
