defmodule Liddr.Rides.VehicleCategoryCache do
  @moduledoc false

  use GenServer

  import Ecto.Query

  alias Liddr.Repo
  alias Liddr.Rides.VehicleCategory

  @table __MODULE__

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def fetch_active(category_id) when is_integer(category_id) and category_id > 0 do
    case :ets.lookup(@table, category_id) do
      [{^category_id, %VehicleCategory{is_active: true} = category}] -> {:ok, category}
      _ -> load_active(category_id)
    end
  end

  def fetch_active(_category_id), do: {:error, :vehicle_category_not_found}

  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end

  @impl true
  def init(:ok) do
    _ =
      :ets.new(@table, [
        :named_table,
        :public,
        :set,
        {:read_concurrency, true},
        {:write_concurrency, true}
      ])

    {:ok, %{}, {:continue, :prewarm}}
  end

  @impl true
  def handle_continue(:prewarm, state) do
    from(vc in VehicleCategory, where: vc.is_active == true)
    |> Repo.all()
    |> Enum.each(fn category -> :ets.insert(@table, {category.id, category}) end)

    {:noreply, state}
  end

  defp load_active(category_id) do
    case Repo.one(
           from vc in VehicleCategory, where: vc.id == ^category_id and vc.is_active == true
         ) do
      %VehicleCategory{} = category ->
        :ets.insert(@table, {category_id, category})
        {:ok, category}

      _ ->
        {:error, :vehicle_category_not_found}
    end
  end
end
