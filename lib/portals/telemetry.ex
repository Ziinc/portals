defmodule Portals.Telemetry do
  @moduledoc """
  The `:telemetry` contract emitted by Portals (Phase 8).

  Every event below is emitted with `:telemetry.execute/3`. Measurements
  are numeric (durations in native time units, convert with
  `System.convert_time_unit/3`); metadata always includes `:module` and
  `:function` when the event is about a specific RPC, plus connection/pool
  identifying fields where relevant.

  ## Events

    * `[:portals, :call, :start]` — measurements: `%{system_time: t}`;
      metadata: `%{connection: pid, module: binary, function: binary,
      request_id: integer}`.
    * `[:portals, :call, :stop]` — measurements: `%{duration: t}`;
      metadata: same as `:start` plus `%{result: :ok | :error}`.
    * `[:portals, :call, :exception]` — measurements: `%{duration: t}`;
      metadata: same as `:start` plus `%{kind: term, reason: term}`.
    * `[:portals, :worker, :start]` — measurements: `%{system_time: t}`;
      metadata: `%{connection: pid, kind: :base | :overflow | :single}`.
    * `[:portals, :worker, :stop]` — measurements: `%{system_time: t}`;
      metadata: `%{connection: pid, reason: term}`.
    * `[:portals, :worker, :crash]` — measurements: `%{system_time: t}`;
      metadata: `%{connection: pid, reason: term}`.
    * `[:portals, :codec, :encode, :stop]` — measurements: `%{duration:
      t, size: bytes}`; metadata: `%{codec: module}`.
    * `[:portals, :codec, :decode, :stop]` — measurements: `%{duration:
      t, size: bytes}`; metadata: `%{codec: module}`.

  Attach with `:telemetry.attach/4` or `:telemetry.attach_many/4`, e.g.:

      :telemetry.attach(
        "log-slow-calls",
        [:portals, :call, :stop],
        fn _event, %{duration: d}, meta, _config ->
          if System.convert_time_unit(d, :native, :millisecond) > 100 do
            Logger.warning("slow call \#{meta.module}.\#{meta.function}")
          end
        end,
        nil
      )

  See `docs/telemetry.md` for the full contract and `Portals.Health` for
  point-in-time snapshots rather than event streams.
  """

  @call_start [:portals, :call, :start]
  @call_stop [:portals, :call, :stop]
  @call_exception [:portals, :call, :exception]
  @worker_start [:portals, :worker, :start]
  @worker_stop [:portals, :worker, :stop]
  @worker_crash [:portals, :worker, :crash]
  @codec_encode_stop [:portals, :codec, :encode, :stop]
  @codec_decode_stop [:portals, :codec, :decode, :stop]

  @doc false
  def call_start(metadata) do
    :telemetry.execute(@call_start, %{system_time: System.system_time()}, metadata)
  end

  @doc false
  def call_stop(start_time, result, metadata) do
    :telemetry.execute(
      @call_stop,
      %{duration: System.monotonic_time() - start_time},
      Map.put(metadata, :result, result)
    )
  end

  @doc false
  def call_exception(start_time, kind, reason, metadata) do
    :telemetry.execute(
      @call_exception,
      %{duration: System.monotonic_time() - start_time},
      metadata |> Map.put(:kind, kind) |> Map.put(:reason, reason)
    )
  end

  @doc false
  def worker_start(metadata) do
    :telemetry.execute(@worker_start, %{system_time: System.system_time()}, metadata)
  end

  @doc false
  def worker_stop(metadata) do
    :telemetry.execute(@worker_stop, %{system_time: System.system_time()}, metadata)
  end

  @doc false
  def worker_crash(metadata) do
    :telemetry.execute(@worker_crash, %{system_time: System.system_time()}, metadata)
  end

  @doc false
  def codec_encode_stop(duration, size, metadata) do
    :telemetry.execute(
      @codec_encode_stop,
      %{duration: duration, size: size},
      metadata
    )
  end

  @doc false
  def codec_decode_stop(duration, size, metadata) do
    :telemetry.execute(
      @codec_decode_stop,
      %{duration: duration, size: size},
      metadata
    )
  end
end
