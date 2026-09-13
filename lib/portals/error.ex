defmodule Portals.Error do
  @moduledoc """
  The single failure representation returned to every Portals caller
  (FR-4). All non-`{:ok, value}` outcomes are `{:error, %Portals.Error{}}`.
  """

  @enforce_keys [:kind, :message]
  defstruct kind: nil,
            message: nil,
            details: %{},
            remote: nil,
            stacktrace: nil

  @type kind ::
          :transport
          | :protocol
          | :remote
          | :checkout_timeout
          | :execution_timeout
          | :cancelled
          | :overload
          | :worker_exit

  @type t :: %__MODULE__{
          kind: kind,
          message: binary,
          details: map,
          remote: map | nil,
          stacktrace: [binary] | nil
        }

  @max_message_size 4096
  @max_stacktrace_frames 64

  # Referenced here as literals so the atoms are guaranteed to already
  # exist in the atom table before `from_wire/1` calls
  # `String.to_existing_atom/1` on wire-supplied kind text.
  @known_kinds [
    :transport,
    :protocol,
    :remote,
    :checkout_timeout,
    :execution_timeout,
    :cancelled,
    :overload,
    :worker_exit
  ]

  @spec known_kinds() :: [kind]
  def known_kinds, do: @known_kinds

  @spec new(kind, binary, keyword) :: t
  def new(kind, message, opts \\ []) do
    %__MODULE__{
      kind: kind,
      message: bound_message(message),
      details: Keyword.get(opts, :details, %{}),
      remote: Keyword.get(opts, :remote),
      stacktrace: opts |> Keyword.get(:stacktrace) |> bound_stacktrace()
    }
  end

  @doc "Build a `%Portals.Error{}` from a decoded wire `ERROR` frame's error map."
  @spec from_wire(map) :: t
  def from_wire(%{} = error_map) do
    kind =
      case Map.get(error_map, "kind", "remote") do
        k when is_binary(k) -> String.to_existing_atom(k)
        k when is_atom(k) -> k
      end

    new(kind, Map.get(error_map, "message", ""),
      details: Map.get(error_map, "details", %{}),
      remote: Map.get(error_map, "remote"),
      stacktrace: Map.get(error_map, "stacktrace")
    )
  rescue
    ArgumentError ->
      new(:remote, Map.get(error_map, "message", "unknown remote error"),
        details: Map.get(error_map, "details", %{}),
        remote: Map.get(error_map, "remote"),
        stacktrace: Map.get(error_map, "stacktrace")
      )
  end

  defp bound_message(message) when is_binary(message) do
    if byte_size(message) > @max_message_size do
      binary_part(message, 0, @max_message_size)
    else
      message
    end
  end

  defp bound_message(message), do: inspect(message) |> bound_message()

  defp bound_stacktrace(nil), do: nil

  defp bound_stacktrace(frames) when is_list(frames) do
    Enum.take(frames, @max_stacktrace_frames)
  end

  defp bound_stacktrace(other), do: [inspect(other)]
end
