defmodule Liddr.Location.Redis do
  @moduledoc false

  @pool_name Liddr.RedisPool

  def child_spec(_opts) do
    case redis_url() do
      url when is_binary(url) and byte_size(url) > 0 ->
        PartitionSupervisor.child_spec(
          child_spec: {Redix, {url, [sync_connect: false]}},
          name: @pool_name,
          partitions: pool_size()
        )

      _ ->
        nil
    end
  end

  def command(command, opts \\ []) when is_list(command) do
    Redix.command(via_partition(command), command, opts)
  rescue
    _ -> {:error, :redis_unavailable}
  catch
    :exit, _ -> {:error, :redis_unavailable}
  end

  def pipeline(commands, opts \\ []) when is_list(commands) do
    Redix.pipeline(via_partition(commands), commands, opts)
  rescue
    _ -> {:error, :redis_unavailable}
  catch
    :exit, _ -> {:error, :redis_unavailable}
  end

  defp redis_url do
    Application.get_env(:liddr, __MODULE__, [])[:url] || System.get_env("REDIS_URL")
  end

  defp via_partition(key), do: {:via, PartitionSupervisor, {@pool_name, key}}

  defp pool_size do
    default_pool_size = max(System.schedulers_online(), 4)

    Application.get_env(:liddr, __MODULE__, [])
    |> Keyword.get(:pool_size, default_pool_size)
    |> normalize_positive_integer(default_pool_size)
  end

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp normalize_positive_integer(value, default) when is_float(value),
    do: normalize_positive_integer(round(value), default)

  defp normalize_positive_integer(_value, default), do: default
end
