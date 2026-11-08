defmodule LiddrWeb.ApiContractTest do
  use ExUnit.Case, async: true

  test "docs/API_CONTRACT.md stays in sync with router contract generator" do
    path = LiddrWeb.ApiContract.contract_path()
    expected = normalize(LiddrWeb.ApiContract.render_markdown())
    actual = path |> File.read!() |> normalize()

    assert actual == expected,
           "API contract drift detected. Run `mix liddr.contract.sync` from `api/`."
  end

  defp normalize(content) do
    content
    |> String.replace("\r\n", "\n")
    |> String.trim()
  end
end
