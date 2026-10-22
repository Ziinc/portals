defmodule Portals.LogSink do
  @moduledoc """
  A configurable destination for Portals operational log events (Phase 8),
  independent of `Logger` and of `:telemetry` event consumers.

  A sink is either:

    * a 1-arity function `fun.(event)`, called synchronously; or
    * `{:file, path}`, which appends one JSON-ish inspect-formatted line
      per event to `path` (the file is opened in `:append` mode on first
      write and kept open for the life of the sink).

  Configure a sink with `attach/1` and remove it with `detach/1`. Multiple
  sinks may be attached at once; `emit/1` calls every attached sink.
  """

  use GenServer

  @type event :: %{
          required(:level) => :debug | :info | :warning | :error,
          required(:message) => binary,
          optional(atom) => term
        }
  @type sink :: (event -> any) | {:file, Path.t()}

  @doc "Start the log sink registry (usually placed under `Portals.Application`'s supervision tree)."
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts \\ []) do
    gen_opts =
      case Keyword.get(opts, :name, __MODULE__) do
        nil -> []
        name -> [name: name]
      end

    GenServer.start_link(__MODULE__, %{}, gen_opts)
  end

  @doc "Register `sink` under `id` (any term); replaces an existing sink registered under the same id."
  @spec attach(term, sink, GenServer.server()) :: :ok
  def attach(id, sink, server \\ __MODULE__), do: GenServer.call(server, {:attach, id, sink})

  @doc "Remove the sink registered under `id`."
  @spec detach(term, GenServer.server()) :: :ok
  def detach(id, server \\ __MODULE__), do: GenServer.call(server, {:detach, id})

  @doc "Deliver `event` to every attached sink."
  @spec emit(event, GenServer.server()) :: :ok
  def emit(event, server \\ __MODULE__) do
    GenServer.cast(server, {:emit, event})
  end

  @impl true
  def init(_), do: {:ok, %{sinks: %{}, files: %{}}}

  @impl true
  def handle_call({:attach, id, sink}, _from, state) do
    {:reply, :ok, %{state | sinks: Map.put(state.sinks, id, sink)}}
  end

  def handle_call({:detach, id}, _from, state) do
    state = close_file_for(id, state)
    {:reply, :ok, %{state | sinks: Map.delete(state.sinks, id)}}
  end

  @impl true
  def handle_cast({:emit, event}, state) do
    state =
      Enum.reduce(state.sinks, state, fn {id, sink}, acc -> deliver(id, sink, event, acc) end)

    {:noreply, state}
  end

  defp deliver(_id, fun, event, state) when is_function(fun, 1) do
    fun.(event)
    state
  rescue
    _ -> state
  end

  defp deliver(id, {:file, path}, event, state) do
    {io, files} =
      case Map.fetch(state.files, id) do
        {:ok, io} -> {io, state.files}
        :error -> open_file(id, path, state.files)
      end

    IO.puts(io, inspect(event))
    %{state | files: files}
  end

  defp open_file(id, path, files) do
    {:ok, io} = File.open(path, [:append, :utf8])
    {io, Map.put(files, id, io)}
  end

  defp close_file_for(id, state) do
    case Map.pop(state.files, id) do
      {nil, files} ->
        %{state | files: files}

      {io, files} ->
        File.close(io)
        %{state | files: files}
    end
  end
end
