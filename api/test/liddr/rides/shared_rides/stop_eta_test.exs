defmodule Liddr.Rides.SharedRides.StopEtaTest do
  use ExUnit.Case, async: true

  alias Decimal, as: D
  alias Liddr.Rides.Ride
  alias Liddr.Rides.SharedRides.StopEta

  test "annotates stops with cumulative ETA using fallback model" do
    ride = %Ride{pickup_lat: D.new("-1.3000000"), pickup_lng: D.new("36.8000000")}
    now = ~U[2026-03-04 10:00:00.000000Z]

    stops = [
      %{member_id: 1, stop_type: "pickup", lat: -1.3000000, lng: 36.8000000},
      %{member_id: 1, stop_type: "dropoff", lat: -1.2950000, lng: 36.8000000}
    ]

    previous = Application.get_env(:liddr, StopEta)

    Application.put_env(:liddr, StopEta,
      google_enabled: false,
      fallback_speed_kph: 30.0,
      min_leg_seconds: 60,
      max_leg_seconds: 7_200
    )

    on_exit(fn -> Application.put_env(:liddr, StopEta, previous || []) end)

    [first, second] = StopEta.annotate(stops, ride, now)

    assert first.metadata["eta_source"] == "fallback_haversine"
    assert first.metadata["eta_leg_seconds"] == 60
    assert DateTime.diff(first.eta_at, now, :second) == 60
    assert DateTime.compare(second.eta_at, first.eta_at) == :gt
  end
end
