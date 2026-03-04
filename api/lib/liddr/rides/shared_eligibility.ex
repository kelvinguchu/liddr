defmodule Liddr.Rides.SharedEligibility do
  @moduledoc false

  alias Liddr.Rides.VehicleCategory

  @disallowed_slugs ~w(motorbike electric_motorbike)

  def ensure_supported_for_category("shared", %VehicleCategory{slug: slug})
      when slug in @disallowed_slugs,
      do: {:error, :shared_not_supported_for_category}

  def ensure_supported_for_category(_product_type, %VehicleCategory{}), do: :ok
end
