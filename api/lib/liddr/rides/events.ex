defmodule Liddr.Rides.Events do
  import Ecto.Query

  alias Liddr.Repo
  alias Liddr.Rides.RideEvent
  alias Liddr.Subscriptions.PaymentUtils

  @default_limit 50
  @max_limit 200

  def record_event(ride_id, event_type, occurred_at, opts \\ []) do
    payload = Keyword.get(opts, :payload, %{}) |> normalize_payload()
    actor_user_id = Keyword.get(opts, :actor_user_id)

    %RideEvent{}
    |> RideEvent.create_changeset(%{
      "ride_id" => ride_id,
      "actor_user_id" => actor_user_id,
      "event_type" => to_string(event_type),
      "payload" => payload,
      "occurred_at" => occurred_at
    })
    |> Repo.insert()
  end

  def list_for_ride(ride_id, attrs \\ %{}) do
    limit = resolve_limit(attrs)
    since = parse_since(attrs)

    query =
      from e in RideEvent,
        where: e.ride_id == ^ride_id,
        order_by: [asc: e.occurred_at, asc: e.id],
        limit: ^limit

    query =
      if since do
        from e in query, where: e.occurred_at > ^since
      else
        query
      end

    events = Repo.all(query)

    {:ok,
     %{
       events: events,
       next_since: next_since(events)
     }}
  end

  defp resolve_limit(attrs) do
    attrs
    |> PaymentUtils.get_value(:limit)
    |> parse_positive_integer()
    |> case do
      nil -> @default_limit
      n when n > @max_limit -> @max_limit
      n -> n
    end
  end

  defp parse_since(attrs) do
    attrs
    |> PaymentUtils.get_value(:since)
    |> parse_datetime()
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(String.trim(value)) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: value

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp parse_positive_integer(_value), do: nil

  defp next_since([]), do: nil
  defp next_since(events), do: events |> List.last() |> Map.get(:occurred_at)
  defp normalize_payload(%{} = payload), do: payload
  defp normalize_payload(_payload), do: %{}
end
