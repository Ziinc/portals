defmodule Portals.SocketDir do
  @moduledoc """
  Private per-worker runtime directory and Unix-domain socket path
  management (FR-1). Every worker gets its own `0700` directory beneath a
  shared Portals runtime root; stale sockets are removed deterministically
  before a new listener binds to the same path.
  """

  @default_root_env "PORTALS_RUNTIME_DIR"

  @spec runtime_root() :: binary
  def runtime_root do
    System.get_env(@default_root_env) || Path.join(System.tmp_dir!(), "portals")
  end

  @doc """
  Create a fresh private `0700` directory for one worker and return the
  Unix-domain socket path inside it. Any pre-existing socket file at that
  path (from an unclean previous shutdown) is removed first.
  """
  @spec allocate(binary) :: {:ok, dir :: binary, socket_path :: binary} | {:error, term}
  def allocate(worker_id) when is_binary(worker_id) do
    dir = Path.join(runtime_root(), worker_id)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700) do
      socket_path = Path.join(dir, "worker.sock")
      File.rm(socket_path)
      {:ok, dir, socket_path}
    end
  end

  @doc "Deterministically remove a worker's runtime directory and any socket file inside it."
  @spec cleanup(binary) :: :ok
  def cleanup(dir) when is_binary(dir) do
    File.rm_rf(dir)
    :ok
  end
end
