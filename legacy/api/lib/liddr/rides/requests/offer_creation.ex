defmodule Liddr.Rides.Requests.OfferCreation do
  @moduledoc false

  alias Liddr.Repo
  alias Liddr.Rides.DriverOfferLock
  alias Liddr.Rides.RideOffer

  def create_initial_offers!(ride_id, driver_candidates, now, offer_ttl_seconds) do
    expires_at = DateTime.add(now, offer_ttl_seconds, :second)
    candidate_index = Map.new(driver_candidates, &{&1.driver_id, &1})
    driver_ids = Map.keys(candidate_index)

    lock_result =
      DriverOfferLock.acquire_many(driver_ids, ride_id, offer_ttl_seconds,
        source: "request_initial_offers"
      )

    if DriverOfferLock.unavailable_blocked?(lock_result) do
      DriverOfferLock.emit_blocked_telemetry("request_initial_offers", 1)
      Repo.rollback(:offer_lock_backend_unavailable)
    end

    selected_driver_ids = lock_result.selected_driver_ids
    locked_driver_ids = lock_result.locked_driver_ids

    if selected_driver_ids == [] do
      []
    else
      rows =
        Enum.map(selected_driver_ids, fn driver_id ->
          driver_snapshot =
            candidate_index
            |> Map.get(driver_id, %{})
            |> Map.get(:driver_rating_snapshot)

          %{
            ride_id: ride_id,
            driver_id: driver_id,
            status: "offered",
            offered_at: now,
            expires_at: expires_at,
            metadata: %{"driver_rating_snapshot" => driver_snapshot},
            inserted_at: now,
            updated_at: now
          }
        end)

      {_, returning_rows} =
        Repo.insert_all(RideOffer, rows,
          on_conflict: :nothing,
          conflict_target: [:ride_id, :driver_id],
          returning: [
            :id,
            :ride_id,
            :driver_id,
            :status,
            :offered_at,
            :expires_at,
            :metadata,
            :inserted_at
          ]
        )

      offers =
        returning_rows
        |> normalize_rows()
        |> Enum.map(fn
          %RideOffer{} = offer -> offer
          row when is_map(row) -> struct(RideOffer, row)
        end)

      inserted_driver_ids = offers |> Enum.map(& &1.driver_id) |> MapSet.new()

      locked_driver_ids
      |> Enum.reject(&MapSet.member?(inserted_driver_ids, &1))
      |> Enum.map(&{&1, ride_id})
      |> DriverOfferLock.release_many(source: "request_insert_conflict")

      offers
    end
  end

  defp normalize_rows(nil), do: []
  defp normalize_rows(rows) when is_list(rows), do: rows
  defp normalize_rows(row), do: [row]
end
