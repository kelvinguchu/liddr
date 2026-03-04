defmodule Liddr.Rides.CategoryRouting do
  @moduledoc false

  def for_category(slug, now \\ DateTime.utc_now()) do
    departure_time =
      now
      |> DateTime.add(90, :second)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    %{
      travel_mode: travel_mode_for(slug),
      routing_preference: routing_preference_for(slug),
      departure_time: departure_time
    }
  end

  defp travel_mode_for("motorbike"), do: "TWO_WHEELER"
  defp travel_mode_for("electric_motorbike"), do: "TWO_WHEELER"
  defp travel_mode_for(_slug), do: "DRIVE"

  defp routing_preference_for("motorbike"), do: "TRAFFIC_AWARE"
  defp routing_preference_for("electric_motorbike"), do: "TRAFFIC_AWARE"
  defp routing_preference_for(_slug), do: "TRAFFIC_AWARE_OPTIMAL"
end
