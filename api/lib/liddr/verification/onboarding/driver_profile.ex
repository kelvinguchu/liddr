defmodule Liddr.Verification.Onboarding.DriverProfile do
  alias Liddr.Accounts.Driver
  alias Liddr.Repo
  alias Liddr.Verification.Shared

  def ensure_driver_profile!(driver_user_id, attrs, now) do
    case Repo.get(Driver, driver_user_id) do
      nil ->
        vehicle_category_id =
          attrs
          |> Shared.get_value(:vehicle_category_id)
          |> Shared.parse_integer()

        if is_nil(vehicle_category_id) do
          Repo.rollback(:missing_vehicle_category_id)
        end

        driver_attrs = %{
          "user_id" => driver_user_id,
          "vehicle_category_id" => vehicle_category_id,
          "license_no" => Shared.get_value(attrs, :license_no),
          "plate_no" => Shared.get_value(attrs, :plate_no),
          "vehicle_year" => Shared.parse_integer(Shared.get_value(attrs, :vehicle_year)),
          "subscription_status" => "inactive",
          "is_available" => false,
          "account_status" => "pending",
          "verification_status" => "pending",
          "activated_at" => nil,
          "last_online_at" => nil,
          "last_seen_at" => now
        }

        %Driver{}
        |> Driver.create_changeset(driver_attrs)
        |> Repo.insert()
        |> case do
          {:ok, driver} -> driver
          {:error, changeset} -> Repo.rollback(changeset)
        end

      %Driver{} = driver ->
        update_attrs =
          %{}
          |> put_if_present(
            "vehicle_category_id",
            Shared.parse_integer(Shared.get_value(attrs, :vehicle_category_id))
          )
          |> put_if_present("license_no", Shared.get_value(attrs, :license_no))
          |> put_if_present("plate_no", Shared.get_value(attrs, :plate_no))
          |> put_if_present(
            "vehicle_year",
            Shared.parse_integer(Shared.get_value(attrs, :vehicle_year))
          )

        if map_size(update_attrs) == 0 do
          driver
        else
          driver
          |> Driver.create_changeset(update_attrs)
          |> Repo.update()
          |> case do
            {:ok, updated_driver} -> updated_driver
            {:error, changeset} -> Repo.rollback(changeset)
          end
        end
    end
  end

  def ensure_driver_pending_status!(driver, now) do
    desired_status =
      case driver.verification_status do
        "approved" -> "approved"
        _ -> "pending"
      end

    desired_account_status =
      case driver.account_status do
        "suspended" -> "suspended"
        "deactivated" -> "deactivated"
        _ -> "pending"
      end

    if driver.verification_status == desired_status and
         driver.account_status == desired_account_status do
      driver
    else
      driver
      |> Driver.create_changeset(%{
        "verification_status" => desired_status,
        "account_status" => desired_account_status,
        "last_seen_at" => now
      })
      |> Repo.update()
      |> case do
        {:ok, updated_driver} -> updated_driver
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)
end
