defmodule Bench.Python do
  @moduledoc "The suite's Python: `bench/.venv` (see setup.sh) and its scripts."

  @root Path.expand("../..", __DIR__)

  def executable do
    path = Path.join(@root, ".venv/bin/python")
    File.exists?(path) || raise "#{path} is missing: run bench/setup.sh first"
    path
  end

  def script(name), do: Path.join([@root, "python", name])
  def dir, do: Path.join(@root, "python")

  @doc """
  Starts `python <script> <args>` as an OS process. With `wait_for_ready`,
  blocks until it prints `ready`. Returns the port.
  """
  def spawn(script, args, opts \\ []) do
    port =
      Port.open({:spawn_executable, executable()}, [
        :binary,
        :exit_status,
        {:args, [script(script) | args]} | Keyword.get(opts, :port_opts, [{:line, 256}])
      ])

    if opts[:wait_for_ready], do: await_ready(port)
    port
  end

  @doc "Kills the OS process behind `port`."
  def kill(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        System.cmd("kill", ["-9", Integer.to_string(pid)], stderr_to_stdout: true)
        Port.close(port)

      nil ->
        :ok
    end

    :ok
  catch
    :error, :badarg -> :ok
  end

  defp await_ready(port) do
    receive do
      {^port, {:data, {:eol, "ready"}}} -> :ok
      {^port, {:exit_status, status}} -> raise "#{inspect(port)} exited with #{status}"
    after
      30_000 -> raise "timed out waiting for #{inspect(port)} to be ready"
    end
  end

  @doc "A free TCP port on 127.0.0.1."
  def free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
