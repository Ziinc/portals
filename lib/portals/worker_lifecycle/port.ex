defmodule Portals.WorkerLifecycle.Port do
  @moduledoc """
  Launches and monitors the direct worker process through a BEAM Port
  (FR-1). Owns only the direct child process — descendant processes the
  worker itself spawns are not tracked or reaped; applications that need
  process-tree ownership must wrap the worker in a container or process
  group of their own.

  Two transport modes:

    * `:unix` (default) — the port is opened only for lifecycle
      monitoring (`:exit_status`) and to observe stray stdout/stderr as
      diagnostic output; RPC data flows over a separate
      `Portals.Transport.Unix` socket.
    * `:stdio` — the port itself carries framed RPC data
      (`{:packet, 4}`); it is opened by `Portals.Connection`, not here,
      since the transport and the port are the same resource in that mode.
  """

  @type launch_opts :: [
          command: binary,
          args: [binary],
          env: [{binary, binary}],
          cd: binary
        ]

  @doc """
  Launch the worker for the `:unix` transport mode: the port is used only
  to detect process exit, never for data. No shell is involved —
  `spawn_executable` receives the resolved absolute path and an explicit
  argument list.
  """
  @spec launch(launch_opts) :: {:ok, port} | {:error, term}
  def launch(opts) do
    with {:ok, executable} <- resolve_executable(Keyword.fetch!(opts, :command)) do
      args = Keyword.get(opts, :args, [])
      port_opts = build_port_opts(opts, [:exit_status, :binary, :hide, :stderr_to_stdout])

      port = Port.open({:spawn_executable, executable}, [{:args, args} | port_opts])
      {:ok, port}
    end
  end

  @doc "Launch the worker for the `:stdio` transport mode: the port itself is the framed data channel."
  @spec launch_stdio(launch_opts) :: {:ok, port} | {:error, term}
  def launch_stdio(opts) do
    with {:ok, executable} <- resolve_executable(Keyword.fetch!(opts, :command)) do
      args = Keyword.get(opts, :args, [])
      port_opts = build_port_opts(opts, [:exit_status, :binary, :hide, :use_stdio, packet: 4])

      port = Port.open({:spawn_executable, executable}, [{:args, args} | port_opts])
      {:ok, port}
    end
  end

  @doc "The OS process id of a launched worker, when available."
  @spec os_pid(port) :: {:ok, non_neg_integer} | :error
  def os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> {:ok, pid}
      nil -> :error
    end
  end

  @doc """
  Gracefully terminate: assumes the caller has already asked the worker to
  exit cooperatively (e.g. by sending a `SHUTDOWN` frame over RPC) and
  waits up to `deadline_ms` for the port to report `{:exit_status, _}`.
  If the deadline elapses, sends `SIGKILL` to the OS process directly
  (never to any descendant it may itself have spawned) and closes the port.
  """
  @spec terminate(port, non_neg_integer) :: :ok
  def terminate(port, deadline_ms) do
    receive do
      {^port, {:exit_status, _}} -> :ok
    after
      deadline_ms -> force_kill(port)
    end
  end

  defp force_kill(port) do
    case os_pid(port) do
      {:ok, pid} -> System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
      :error -> :ok
    end

    safe_close(port)
  end

  defp safe_close(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp build_port_opts(opts, base) do
    env = Keyword.get(opts, :env, [])
    cd = Keyword.get(opts, :cd)

    charlist_env = Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    base
    |> maybe_add(:env, charlist_env, env != [])
    |> maybe_add(:cd, cd, cd != nil)
  end

  defp maybe_add(list, _key, _value, false), do: list
  defp maybe_add(list, key, value, true), do: [{key, value} | list]

  defp resolve_executable(command) do
    case System.find_executable(command) do
      nil ->
        if File.exists?(command) do
          {:ok, command}
        else
          {:error, {:executable_not_found, command}}
        end

      path ->
        {:ok, path}
    end
  end
end
