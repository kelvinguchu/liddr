defmodule Liddr.Rides.DriverLivenessTest do
  use ExUnit.Case, async: true

  alias Liddr.Rides.DriverLiveness

  test "state transitions from online to degraded to offline by signal age" do
    assert DriverLiveness.state_for_age(10) == "online"
    assert DriverLiveness.state_for_age(DriverLiveness.online_max_age_seconds()) == "online"

    assert DriverLiveness.state_for_age(DriverLiveness.online_max_age_seconds() + 1) ==
             "degraded"

    assert DriverLiveness.state_for_age(DriverLiveness.offline_after_seconds()) == "degraded"

    assert DriverLiveness.state_for_age(DriverLiveness.offline_after_seconds() + 1) == "offline"
  end
end
