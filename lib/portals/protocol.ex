defmodule Portals.Protocol do
  @moduledoc """
  Portals wire protocol v1: frame tags, default limits, and the frame
  validation rules shared by every SDK implementation.

  See `protocol/v1.md` for the full specification. This module encodes
  the frame tag registry and default limits as authoritative Elixir
  constants; `protocol/v1.md` must stay in sync with these values.
  """

  @version 1

  # Frame tags. Every encoded frame is a MessagePack array whose first
  # element is one of these integers.
  @frame_tags %{
    hello: 1,
    ready: 2,
    call: 3,
    return: 4,
    error: 5,
    cancel: 6,
    callback: 7,
    callback_return: 8,
    callback_error: 9,
    message: 10,
    stream_data: 11,
    credit: 12,
    half_close: 13,
    ping: 14,
    pong: 15,
    shutdown: 16
  }

  @tag_to_frame Map.new(@frame_tags, fn {frame, tag} -> {tag, frame} end)

  @default_limits %{
    max_frame_size: 16 * 1024 * 1024,
    max_nesting_depth: 32,
    max_collection_length: 65_536,
    max_metadata_size: 65_536,
    max_callback_depth: 16,
    max_in_flight_callbacks: 256,
    max_in_flight_requests: 4096,
    max_stream_byte_credit: 4 * 1024 * 1024,
    max_queued_stream_frames: 1024
  }

  @type frame_name ::
          :hello
          | :ready
          | :call
          | :return
          | :error
          | :cancel
          | :callback
          | :callback_return
          | :callback_error
          | :message
          | :stream_data
          | :credit
          | :half_close
          | :ping
          | :pong
          | :shutdown

  @type limits :: %{
          max_frame_size: pos_integer,
          max_nesting_depth: pos_integer,
          max_collection_length: pos_integer,
          max_metadata_size: pos_integer,
          max_callback_depth: pos_integer,
          max_in_flight_callbacks: pos_integer,
          max_in_flight_requests: pos_integer,
          max_stream_byte_credit: pos_integer,
          max_queued_stream_frames: pos_integer
        }

  @spec version() :: pos_integer
  def version, do: @version

  @spec default_limits() :: limits
  def default_limits, do: @default_limits

  @spec frame_tag(frame_name) :: pos_integer
  def frame_tag(name) when is_map_key(@frame_tags, name), do: Map.fetch!(@frame_tags, name)

  @spec frame_name(pos_integer) :: {:ok, frame_name} | :error
  def frame_name(tag) when is_integer(tag) do
    case Map.fetch(@tag_to_frame, tag) do
      {:ok, name} -> {:ok, name}
      :error -> :error
    end
  end

  @doc "Required and optional field arity for each frame, used to validate a decoded envelope."
  @spec arity(frame_name) :: {non_neg_integer, non_neg_integer | :infinity}
  def arity(:hello), do: {5, 5}
  def arity(:ready), do: {2, 2}
  def arity(:call), do: {4, 6}
  def arity(:return), do: {2, 2}
  def arity(:error), do: {2, 2}
  def arity(:cancel), do: {1, 1}
  def arity(:callback), do: {4, 5}
  def arity(:callback_return), do: {2, 2}
  def arity(:callback_error), do: {2, 2}
  def arity(:message), do: {2, 2}
  def arity(:stream_data), do: {2, 2}
  def arity(:credit), do: {2, 3}
  def arity(:half_close), do: {1, 1}
  def arity(:ping), do: {1, 1}
  def arity(:pong), do: {1, 1}
  def arity(:shutdown), do: {0, 1}

  @doc """
  Validate a decoded frame envelope: `[tag | fields]`.

  Returns `{:ok, {frame_name, fields}}` or `{:error, reason}`. Does not
  interpret field semantics beyond arity and the tag itself; that is the
  responsibility of `Portals.Connection` and its equivalents in each SDK.
  """
  @spec validate_envelope(list) :: {:ok, {frame_name, list}} | {:error, term}
  def validate_envelope([tag | fields]) when is_integer(tag) do
    with {:ok, name} <- frame_name(tag),
         {min, max} <- arity(name),
         :ok <- check_arity(length(fields), min, max) do
      {:ok, {name, fields}}
    else
      :error -> {:error, {:unknown_frame_tag, tag}}
      {:error, reason} -> {:error, reason}
    end
  end

  def validate_envelope([]), do: {:error, :empty_envelope}
  def validate_envelope(other), do: {:error, {:malformed_envelope, other}}

  defp check_arity(count, min, :infinity) when count >= min, do: :ok
  defp check_arity(count, min, max) when count >= min and count <= max, do: :ok
  defp check_arity(count, _min, _max), do: {:error, {:bad_arity, count}}
end
