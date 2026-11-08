defmodule Liddr.Maps.RoutesClientBehaviour do
  @callback compute_route(map()) ::
              {:ok,
               %{
                 distance_m: pos_integer(),
                 duration_s: pos_integer(),
                 static_duration_s: non_neg_integer() | nil,
                 polyline: String.t() | nil,
                 raw: map()
               }}
              | {:error, term()}
end
