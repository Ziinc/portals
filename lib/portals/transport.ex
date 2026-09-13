defmodule Portals.Transport do
  @moduledoc """
  Transport behaviour for moving framed bytes between the BEAM and a
  worker. A transport does not know about frame contents; it only owns
  byte delivery and must deliver received bytes as Erlang messages to the
  owning process so a `Portals.Connection`-style GenServer can multiplex
  transport I/O with call handling in its normal message loop.

  `Portals.Transport.Unix` (default) and `Portals.Transport.Stdio`
  (fallback, used automatically on platforms without Unix-domain socket
  support) both implement this behaviour.
  """

  @type socket :: term

  @doc "Start listening for the worker's single incoming connection."
  @callback listen(opts :: keyword) :: {:ok, socket} | {:error, term}

  @doc "Block (up to `timeout`) for the worker to connect."
  @callback accept(socket, timeout) :: {:ok, socket} | {:error, term}

  @doc "Send raw bytes."
  @callback send(socket, iodata) :: :ok | {:error, term}

  @doc "Stop delivering data to the caller and release transport resources."
  @callback close(socket) :: :ok
end
