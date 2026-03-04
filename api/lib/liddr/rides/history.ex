defmodule Liddr.Rides.History do
  import Ecto.Query

  alias Liddr.Repo
  alias Liddr.Rides.Ride
  alias Liddr.Rides.SharedRides.Access
  alias Liddr.Subscriptions.PaymentUtils

  def rider_history(rider_user_id, attrs \\ %{}) do
    limit = resolve_limit(attrs)

    rides =
      Ride
      |> Access.rider_scope(rider_user_id)
      |> order_by([r], desc: r.inserted_at)
      |> limit(^limit)
      |> Repo.all()

    {:ok, rides}
  end

  def driver_history(driver_user_id, attrs \\ %{}) do
    limit = resolve_limit(attrs)

    rides =
      Repo.all(
        from r in Ride,
          where: r.driver_id == ^driver_user_id,
          order_by: [desc: r.inserted_at],
          limit: ^limit
      )

    {:ok, rides}
  end

  defp resolve_limit(attrs) do
    attrs
    |> PaymentUtils.get_value(:limit)
    |> parse_positive_integer()
    |> case do
      nil -> 20
      n when n > 100 -> 100
      n -> n
    end
  end

  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: value

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp parse_positive_integer(_value), do: nil
end
