defmodule Liddr.Rides.Integrity.PolicyTest do
  use ExUnit.Case, async: false

  alias Liddr.Rides.Integrity.Policy

  test "runtime overrides take precedence over defaults" do
    previous = Application.get_env(:liddr, Policy, [])

    on_exit(fn ->
      if previous == [] do
        Application.delete_env(:liddr, Policy)
      else
        Application.put_env(:liddr, Policy, previous)
      end
    end)

    Application.put_env(:liddr, Policy, rider_chargeable_threshold: 9)
    assert Policy.rider_chargeable_threshold() == 9
  end
end
