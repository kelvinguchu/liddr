defmodule Liddr.Location.S2Native.Worker do
  @moduledoc false

  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{})
  end

  @impl true
  def init(_state) do
    {:ok, %{port: open_port(), from: nil, queue: :queue.new()}}
  end

  @impl true
  def handle_call({:execute, args}, from, state) do
    {:noreply, enqueue_or_dispatch(state, {from, args})}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port, from: from} = state)
      when not is_nil(from) do
    GenServer.reply(from, decode_response(line))
    {:noreply, dispatch_next(%{state | from: nil})}
  end

  def handle_info({port, {:data, {:noeol, partial}}}, %{port: port, from: from} = state)
      when not is_nil(from) do
    message = "s2 helper produced oversized response: #{partial}"
    GenServer.reply(from, {:error, message})
    {:stop, :helper_invalid_response, %{state | from: nil}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port, from: from} = state) do
    error = {:error, "s2 helper exited with status #{status}"}

    if from, do: GenServer.reply(from, error)
    reply_pending(state.queue, error)

    {:stop, {:helper_exit, status}, %{state | from: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port) do
    Port.close(port)
    :ok
  catch
    :exit, _ -> :ok
  end

  def terminate(_reason, _state), do: :ok

  defp open_port do
    Port.open({:spawn_executable, Liddr.Location.S2Native.helper_path()}, [
      :binary,
      :exit_status,
      {:args, ["serve"]},
      {:line, 65_536},
      :use_stdio,
      :stderr_to_stdout,
      :hide
    ])
  end

  defp decode_response("ok"), do: {:ok, []}

  defp decode_response("ok\t" <> tokens) do
    {:ok, String.split(tokens, "\t", trim: true)}
  end

  defp decode_response("error\t" <> message), do: {:error, message}
  defp decode_response(message), do: {:error, "unexpected s2 helper response: #{message}"}

  defp enqueue_or_dispatch(%{from: nil} = state, request), do: dispatch_request(state, request)

  defp enqueue_or_dispatch(state, request) do
    %{state | queue: :queue.in(request, state.queue)}
  end

  defp dispatch_next(%{from: nil, queue: queue} = state) do
    case :queue.out(queue) do
      {{:value, request}, next_queue} ->
        dispatch_request(%{state | queue: next_queue}, request)

      {:empty, _queue} ->
        state
    end
  end

  defp dispatch_next(state), do: state

  defp dispatch_request(state, {from, args}) do
    payload = Enum.join(args, "\t") <> "\n"
    true = Port.command(state.port, payload)
    %{state | from: from}
  end

  defp reply_pending(queue, reply) do
    queue
    |> :queue.to_list()
    |> Enum.each(fn {from, _args} -> GenServer.reply(from, reply) end)
  end
end
