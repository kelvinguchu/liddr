defmodule Liddr.TestSupport.FakeRedis do
  @moduledoc false

  @agent_name __MODULE__

  def reset! do
    ensure_started()
    Agent.update(@agent_name, fn _ -> %{} end)
  end

  def command(command, _opts \\ []) when is_list(command) do
    ensure_started()

    Agent.get_and_update(@agent_name, fn state ->
      {result, updated_state} = execute(command, state)
      {{:ok, result}, updated_state}
    end)
  end

  def pipeline(commands, _opts \\ []) when is_list(commands) do
    ensure_started()

    Agent.get_and_update(@agent_name, fn state ->
      {results, updated_state} =
        Enum.map_reduce(commands, state, fn command, acc ->
          execute(command, acc)
        end)

      {{:ok, results}, updated_state}
    end)
  end

  defp ensure_started do
    case Process.whereis(@agent_name) do
      nil ->
        start_agent()

      _pid ->
        :ok
    end
  end

  defp start_agent do
    case Agent.start(fn -> %{} end, name: @agent_name) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp execute(["INCR", key], state) do
    current = to_integer(Map.get(state, key, 0))
    next = current + 1
    {next, Map.put(state, key, next)}
  end

  defp execute(["EXPIRE", _key, _ttl], state), do: {1, state}

  defp execute(["SADD", key, member], state) do
    set =
      state
      |> Map.get(key, MapSet.new())
      |> ensure_set()

    updated = MapSet.put(set, to_string(member))
    added = if MapSet.size(updated) > MapSet.size(set), do: 1, else: 0
    {added, Map.put(state, key, updated)}
  end

  defp execute(["SREM", key, member], state) do
    set =
      state
      |> Map.get(key, MapSet.new())
      |> ensure_set()

    updated = MapSet.delete(set, to_string(member))
    removed = if MapSet.size(updated) < MapSet.size(set), do: 1, else: 0
    {removed, Map.put(state, key, updated)}
  end

  defp execute(["SMEMBERS", key], state) do
    members =
      state
      |> Map.get(key, MapSet.new())
      |> ensure_set()
      |> MapSet.to_list()

    {members, state}
  end

  defp execute(["HGETALL", key], state) do
    fields =
      state
      |> Map.get(key, %{})
      |> ensure_hash()
      |> Enum.flat_map(fn {field, value} -> [field, value] end)

    {fields, state}
  end

  defp execute(["HSET", key | fields], state) do
    hash =
      state
      |> Map.get(key, %{})
      |> ensure_hash()

    updated =
      fields
      |> Enum.chunk_every(2)
      |> Enum.reduce(hash, fn
        [field, value], acc -> Map.put(acc, to_string(field), to_string(value))
        _pair, acc -> acc
      end)

    {fields |> length() |> div(2), Map.put(state, key, updated)}
  end

  defp execute(["SCARD", key], state) do
    cardinality =
      state
      |> Map.get(key, MapSet.new())
      |> ensure_set()
      |> MapSet.size()

    {cardinality, state}
  end

  defp execute(["DEL", key], state) do
    removed = if Map.has_key?(state, key), do: 1, else: 0
    {removed, Map.delete(state, key)}
  end

  defp execute(_command, state), do: {0, state}

  defp ensure_set(%MapSet{} = set), do: set
  defp ensure_set(_other), do: MapSet.new()

  defp ensure_hash(hash) when is_map(hash) and not is_struct(hash), do: hash
  defp ensure_hash(_other), do: %{}

  defp to_integer(value) when is_integer(value), do: value

  defp to_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> 0
    end
  end

  defp to_integer(_value), do: 0
end
