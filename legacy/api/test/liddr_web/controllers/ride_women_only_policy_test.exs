defmodule LiddrWeb.RideWomenOnlyPolicyTest do
  use LiddrWeb.ConnCase, async: false

  import Ecto.Query

  alias Liddr.Accounts.User
  alias Liddr.Repo
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

  test "rider cannot request women_only ride unless rider gender is female", %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)

    category_id =
      VerificationFixtures.insert_vehicle_category!(%{slug: "women_only", label: "Women Only"})

    request_conn =
      post(rider_conn, "/api/rides/requests", %{
        "vehicle_category_id" => category_id,
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000"
      })

    assert %{"error" => %{"code" => "WOMEN_ONLY_RIDER_NOT_ELIGIBLE"}} =
             json_response(request_conn, 403)
  end

  test "female rider can request women_only ride", %{conn: conn} do
    %{auth_conn: rider_conn, user_id: rider_user_id} = AuthFixtures.authenticate_rider!(conn)

    category_id =
      VerificationFixtures.insert_vehicle_category!(%{slug: "women_only", label: "Women Only"})

    _ =
      Repo.update_all(
        from(u in User, where: u.id == ^rider_user_id),
        set: [gender: "female"]
      )

    request_conn =
      post(rider_conn, "/api/rides/requests", %{
        "vehicle_category_id" => category_id,
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000"
      })

    assert %{"data" => %{"ride" => %{"vehicle_category_id" => ^category_id}}} =
             json_response(request_conn, 201)
  end
end
