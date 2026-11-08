defmodule Liddr.Location.S2Test do
  use ExUnit.Case, async: true

  alias Liddr.Location.S2
  alias Liddr.Location.S2Native

  test "token encodes a canonical lowercase hex cell token" do
    token = S2.token(-1.2921, 36.8219)

    assert is_binary(token)
    assert token =~ ~r/\A[0-9a-f]{1,16}\z/
  end

  test "token matches the official S2 implementation" do
    assert S2.token(-1.2921, 36.8219) == S2Native.token(-1.2921, 36.8219, 13)
    assert S2.token(-1.280524, 36.781406) == S2Native.token(-1.280524, 36.781406, 13)
  end

  test "covering_tokens returns a stable covering including the origin cell" do
    token = S2.token(-1.2921, 36.8219)
    assert {:ok, tokens} = S2.covering_tokens(-1.2921, 36.8219, 2.0)

    assert token in tokens
    assert length(tokens) > 1
    assert tokens == Enum.uniq(tokens)
  end

  test "nearby coordinates map to overlapping coverings" do
    assert {:ok, origin_tokens} = S2.covering_tokens(-1.2921, 36.8219, 1.5)
    assert {:ok, nearby_tokens} = S2.covering_tokens(-1.289, 36.826, 1.5)

    origin = MapSet.new(origin_tokens)
    nearby = MapSet.new(nearby_tokens)

    assert MapSet.size(MapSet.intersection(origin, nearby)) > 0
  end

  test "covering_tokens enforces max_cells without arbitrary truncation in Elixir" do
    assert {:ok, tokens} = S2.covering_tokens(-1.2921, 36.8219, 4.0, 8)
    assert length(tokens) <= 8
  end
end
