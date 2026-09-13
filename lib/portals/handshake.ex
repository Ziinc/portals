defmodule Portals.Handshake do
  @moduledoc """
  Exact-version handshake rules shared by every SDK.

  Wire shape:

      HELLO = [tag=1, protocol_version, runtime, max_concurrency, max_streams, features]
      READY = [tag=2, protocol_version, limits]

  The worker sends `HELLO` first; the BEAM replies with `READY` only when
  `protocol_version` matches `Portals.Protocol.version/0` exactly. Any
  mismatch is a deterministic, unrecoverable startup failure: the
  connection is closed and the worker is not marked ready.
  """

  alias Portals.Protocol

  defmodule Hello do
    @moduledoc "Decoded HELLO fields."
    @enforce_keys [:protocol_version, :runtime, :max_concurrency, :max_streams, :features]
    defstruct [:protocol_version, :runtime, :max_concurrency, :max_streams, :features]

    @type t :: %__MODULE__{
            protocol_version: pos_integer,
            runtime: binary,
            max_concurrency: pos_integer,
            max_streams: pos_integer,
            features: [binary]
          }
  end

  @spec build_hello(binary, pos_integer, pos_integer, [binary]) :: list
  def build_hello(runtime, max_concurrency, max_streams, features \\ []) do
    [
      Protocol.frame_tag(:hello),
      Protocol.version(),
      runtime,
      max_concurrency,
      max_streams,
      features
    ]
  end

  @spec build_ready(Protocol.limits()) :: list
  def build_ready(limits) do
    [Protocol.frame_tag(:ready), Protocol.version(), limits_to_list(limits)]
  end

  @doc """
  Validate a decoded HELLO envelope against the BEAM's own protocol version.

  Returns `{:ok, %Hello{}}` only on an exact version match. Any mismatch
  returns `{:error, {:protocol_version_mismatch, expected, actual}}` and
  callers must close the connection without sending `READY`.
  """
  @spec negotiate([term]) ::
          {:ok, Hello.t()}
          | {:error, {:protocol_version_mismatch, pos_integer, term}}
          | {:error, term}
  def negotiate([_tag, version, runtime, max_concurrency, max_streams, features]) do
    if version == Protocol.version() do
      {:ok,
       %Hello{
         protocol_version: version,
         runtime: runtime,
         max_concurrency: max_concurrency,
         max_streams: max_streams,
         features: features
       }}
    else
      {:error, {:protocol_version_mismatch, Protocol.version(), version}}
    end
  end

  def negotiate(other), do: {:error, {:malformed_hello, other}}

  defp limits_to_list(limits) do
    Map.new(limits, fn {k, v} -> {Atom.to_string(k), v} end)
  end
end
