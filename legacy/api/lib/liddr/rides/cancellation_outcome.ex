defmodule Liddr.Rides.CancellationOutcome do
  @moduledoc false

  alias Liddr.Rides.Ride

  def from_ride(%Ride{} = ride) do
    if ride.status == "cancelled", do: from_metadata(ride.metadata), else: nil
  end

  def from_ride(_ride), do: nil

  def from_metadata(%{} = metadata) do
    case Map.get(metadata, "cancellation_outcome") do
      %{} = outcome ->
        outcome

      _ ->
        build_outcome(metadata)
    end
  end

  def from_metadata(_metadata), do: nil

  def enrich_metadata(metadata, integrity, enforcement) do
    metadata = normalize_metadata(metadata)
    outcome = build_outcome(%{"integrity" => integrity, "integrity_enforcement" => enforcement})

    metadata
    |> Map.put("integrity", integrity)
    |> Map.put("integrity_enforcement", enforcement)
    |> maybe_put_outcome(outcome)
  end

  defp maybe_put_outcome(metadata, nil), do: metadata

  defp maybe_put_outcome(metadata, outcome),
    do: Map.put(metadata, "cancellation_outcome", outcome)

  defp build_outcome(metadata) do
    integrity = Map.get(metadata, "integrity")
    enforcement = Map.get(metadata, "integrity_enforcement")

    if is_map(integrity) do
      %{
        "policy_version" => Map.get(integrity, "policy_version"),
        "reason_code" => Map.get(integrity, "reason_code"),
        "violation_type" => Map.get(integrity, "violation_type"),
        "chargeable" => Map.get(integrity, "chargeable"),
        "waiver_code" => Map.get(integrity, "waiver_code"),
        "subject_role" => Map.get(integrity, "subject_role"),
        "subject_user_id" => Map.get(integrity, "subject_user_id"),
        "chargeable_events_7d" => map_value(enforcement, "chargeable_events_7d"),
        "action" => map_value(enforcement, "action")
      }
    else
      nil
    end
  end

  defp map_value(%{} = map, key), do: Map.get(map, key)
  defp map_value(_value, _key), do: nil

  defp normalize_metadata(%{} = metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}
end
