defmodule Liddr.Ratings.Snapshot do
  import Ecto.Query

  alias Decimal, as: D
  alias Liddr.Accounts.User
  alias Liddr.Rides.DispatchPolicy
  alias Liddr.Repo

  @medium_confidence_min_count 30

  def build_index(user_ids) when is_list(user_ids) do
    ids =
      user_ids
      |> Enum.filter(&is_integer/1)
      |> Enum.uniq()

    if ids == [] do
      %{}
    else
      Repo.all(
        from u in User,
          where: u.id in ^ids,
          select: %{id: u.id, rating_score: u.rating_score, rating_count: u.rating_count}
      )
      |> Map.new(fn row -> {row.id, row} end)
    end
  end

  def snapshot_for_role(nil, _role, _index), do: nil

  def snapshot_for_role(user_id, role, index) when is_integer(user_id) and is_map(index) do
    base = base_snapshot(Map.get(index, user_id))

    case role do
      :driver ->
        Map.put(
          base,
          :is_new_driver,
          base.rating_count < DispatchPolicy.new_driver_min_rated_rides()
        )

      :rider ->
        Map.put(
          base,
          :is_new_rider,
          base.rating_count < DispatchPolicy.new_user_min_rated_rides()
        )

      _ ->
        base
    end
  end

  def snapshot_for_user(%User{} = user, role) do
    snapshot_for_values(user.rating_score, user.rating_count, role)
  end

  def snapshot_for_values(rating_score, rating_count, role) do
    %{
      rating_score: rating_score,
      rating_count: rating_count
    }
    |> base_snapshot()
    |> add_role_flag(role)
  end

  defp base_snapshot(nil) do
    %{
      rating_score: nil,
      rating_count: 0,
      confidence_band: "low"
    }
  end

  defp base_snapshot(%{rating_score: rating_score, rating_count: rating_count}) do
    normalized_count = normalize_count(rating_count)

    %{
      rating_score: normalize_score(rating_score),
      rating_count: normalized_count,
      confidence_band: confidence_band(normalized_count)
    }
  end

  defp add_role_flag(base, :driver) do
    Map.put(base, :is_new_driver, base.rating_count < DispatchPolicy.new_driver_min_rated_rides())
  end

  defp add_role_flag(base, :rider) do
    Map.put(base, :is_new_rider, base.rating_count < DispatchPolicy.new_user_min_rated_rides())
  end

  defp add_role_flag(base, _role), do: base

  defp confidence_band(count) do
    cond do
      count >= @medium_confidence_min_count -> "high"
      count >= DispatchPolicy.new_user_min_rated_rides() -> "medium"
      true -> "low"
    end
  end

  defp normalize_count(count) when is_integer(count) and count >= 0, do: count
  defp normalize_count(_count), do: 0

  defp normalize_score(nil), do: nil
  defp normalize_score(%D{} = score), do: score |> D.to_float() |> Float.round(2)
  defp normalize_score(score) when is_number(score), do: (score * 1.0) |> Float.round(2)
  defp normalize_score(_score), do: nil
end
