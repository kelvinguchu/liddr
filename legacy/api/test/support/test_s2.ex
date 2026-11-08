defmodule Liddr.TestS2 do
  @moduledoc false

  def token(_lat, _lng) do
    Application.get_env(:liddr, __MODULE__, [])[:token] || "182f10dc"
  end

  def covering_tokens(_lat, _lng, _radius_km, _max_cells \\ nil) do
    case Application.get_env(:liddr, __MODULE__, [])[:mode] do
      {:ok, tokens} when is_list(tokens) -> {:ok, tokens}
      {:error, reason} -> {:error, reason}
      _ -> {:ok, []}
    end
  end
end
