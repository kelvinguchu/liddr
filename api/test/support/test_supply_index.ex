defmodule Liddr.TestSupplyIndex do
  @moduledoc false

  def candidate_driver_ids(_category_id, _lat, _lng, _radius_km, _max_candidates) do
    case Application.get_env(:liddr, __MODULE__, [])[:mode] do
      {:ok, ids} when is_list(ids) -> {:ok, ids}
      {:error, reason} -> {:error, reason}
      _ -> {:ok, []}
    end
  end
end
