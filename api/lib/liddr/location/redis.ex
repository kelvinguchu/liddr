defmodule Liddr.Location.Redis do
  @moduledoc false

  @client_name Liddr.Redis

  def child_spec(_opts) do
    case redis_url() do
      url when is_binary(url) and byte_size(url) > 0 ->
        %{
          id: @client_name,
          start: {Redix, :start_link, [url, [name: @client_name, sync_connect: false]]},
          type: :worker,
          restart: :permanent,
          shutdown: 5_000
        }

      _ ->
        nil
    end
  end

  def command(command, opts \\ []) when is_list(command) do
    if Process.whereis(@client_name) do
      Redix.command(@client_name, command, opts)
    else
      {:error, :redis_unavailable}
    end
  rescue
    _ -> {:error, :redis_unavailable}
  catch
    :exit, _ -> {:error, :redis_unavailable}
  end

  def pipeline(commands, opts \\ []) when is_list(commands) do
    if Process.whereis(@client_name) do
      Redix.pipeline(@client_name, commands, opts)
    else
      {:error, :redis_unavailable}
    end
  rescue
    _ -> {:error, :redis_unavailable}
  catch
    :exit, _ -> {:error, :redis_unavailable}
  end

  defp redis_url do
    Application.get_env(:liddr, __MODULE__, [])[:url] || System.get_env("REDIS_URL")
  end
end
