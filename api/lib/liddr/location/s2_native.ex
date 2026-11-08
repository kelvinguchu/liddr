defmodule Liddr.Location.S2Native do
  @moduledoc false

  require Logger

  @source_glob Path.expand("../../../native/s2cover/*", __DIR__)
  @helper_basename "s2cover"
  @pool_name __MODULE__.Pool
  def start_link(_opts) do
    case ensure_compiled!() do
      :ok ->
        PartitionSupervisor.start_link(
          child_spec: Liddr.Location.S2Native.Worker,
          name: @pool_name,
          partitions: pool_size()
        )

      {:error, message} ->
        Logger.error("[location.s2_native] helper unavailable, using fallback: #{message}")
        :ignore
    end
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  def token(lat, lng, level)
      when is_number(lat) and is_number(lng) and is_integer(level) and level in 0..30 do
    ["token", format_float(lat), format_float(lng), Integer.to_string(level)]
    |> request()
    |> case do
      {:ok, [token]} -> token
      {:ok, output} -> raise "unexpected s2 token output: #{inspect(output)}"
      {:error, message} -> raise message
    end
  end

  def covering_tokens(lat, lng, radius_km, level, max_cells \\ nil)
      when is_number(lat) and is_number(lng) and is_number(radius_km) and radius_km >= 0 and
             is_integer(level) and level in 0..30 do
    [
      "covering",
      format_float(lat),
      format_float(lng),
      Integer.to_string(level),
      format_float(radius_km)
    ]
    |> maybe_append_max_cells(max_cells)
    |> request()
  end

  def helper_path do
    Application.get_env(:liddr, __MODULE__, [])
    |> Keyword.get_lazy(:helper_path, fn ->
      Application.app_dir(:liddr, Path.join("priv/bin", helper_name()))
    end)
  end

  defp request(args) do
    GenServer.call(via_partition(self()), {:execute, args}, request_timeout_ms())
  rescue
    ArgumentError -> helper_unavailable(:pool_not_started)
  catch
    :exit, reason -> helper_unavailable(reason)
  end

  defp helper_unavailable(reason), do: {:error, "s2 helper unavailable: #{inspect(reason)}"}

  defp via_partition(key), do: {:via, PartitionSupervisor, {@pool_name, key}}

  defp maybe_append_max_cells(args, max_cells) when is_integer(max_cells) and max_cells > 0,
    do: args ++ [Integer.to_string(max_cells)]

  defp maybe_append_max_cells(args, _max_cells), do: args

  defp ensure_compiled! do
    helper_path()
    |> needs_build?()
    |> if do
      build_helper!()
    else
      :ok
    end
  rescue
    error ->
      {:error, Exception.message(error)}
  end

  defp needs_build?(binary_path) do
    cond do
      not File.exists?(binary_path) ->
        true

      true ->
        binary_mtime = mtime!(binary_path)

        @source_glob
        |> Path.wildcard()
        |> Enum.any?(fn path -> mtime!(path) > binary_mtime end)
    end
  end

  defp build_helper! do
    File.mkdir_p!(Path.dirname(helper_path()))

    case System.cmd("go", ["build", "-o", helper_path(), "."],
           cd: source_dir(),
           stderr_to_stdout: true,
           env: [{"CGO_ENABLED", "0"}]
         ) do
      {_output, 0} ->
        :ok

      {output, status} ->
        {:error, "failed to build s2 helper (status #{status}): #{String.trim(output)}"}
    end
  rescue
    error ->
      {:error, Exception.message(error)}
  end

  defp helper_name do
    if match?({:win32, _}, :os.type()) do
      @helper_basename <> ".exe"
    else
      @helper_basename
    end
  end

  defp source_dir do
    Path.expand("../../../native/s2cover", __DIR__)
  end

  defp format_float(value) when is_integer(value), do: Integer.to_string(value)
  defp format_float(value), do: :erlang.float_to_binary(value * 1.0, [:compact, decimals: 12])

  defp mtime!(path) do
    path
    |> File.stat!()
    |> Map.fetch!(:mtime)
    |> NaiveDateTime.from_erl!()
  end

  defp pool_size do
    default_pool_size = max(System.schedulers_online(), 4)

    Application.get_env(:liddr, __MODULE__, [])
    |> Keyword.get(:pool_size, default_pool_size)
    |> normalize_positive_integer(default_pool_size)
  end

  defp request_timeout_ms do
    Application.get_env(:liddr, __MODULE__, [])
    |> Keyword.get(:request_timeout_ms, 5_000)
    |> normalize_positive_integer(5_000)
  end

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp normalize_positive_integer(value, default) when is_float(value),
    do: normalize_positive_integer(round(value), default)

  defp normalize_positive_integer(_value, default), do: default
end
