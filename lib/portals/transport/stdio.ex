defmodule Portals.Transport.Stdio do
  @moduledoc """
  Length-framed stdin/stdout fallback transport, used automatically only
  on platforms where Unix-domain sockets are unsupported. Experimental:
  Linux (the only officially supported 1.0 platform) always uses
  `Portals.Transport.Unix`.

  Unlike the Unix transport, there is no separate listen/accept step: the
  worker's stdin/stdout *is* the connection, opened by
  `Portals.WorkerLifecycle.Port` with the `{:packet, 4}` port option, which
  gives the same length-prefixed framing as the Unix transport's `packet:
  4` socket option. `listen/1` and `accept/2` are no-ops that simply
  adopt the already-open port.
  """

  @behaviour Portals.Transport

  @impl true
  def listen(opts) do
    case Keyword.fetch(opts, :port) do
      {:ok, port} -> {:ok, port}
      :error -> {:error, :port_required}
    end
  end

  @impl true
  def accept(port, _timeout), do: {:ok, port}

  @impl true
  def send(port, data) do
    Port.command(port, data)
    :ok
  rescue
    ArgumentError -> {:error, :closed}
  end

  @impl true
  def close(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
