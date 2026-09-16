# frozen_string_literal: true

require 'portals'

# Function targets used by the Elixir integration tests — the Ruby mirror of
# `sdk/python/tests/fixtures/bench_worker.py`.
module BenchWorker
  extend Portals::StreamHandlers
  module_function

  def echo(value) = value

  def add(a, b) = a + b

  def raise_error(message)
    raise ArgumentError, message
  end

  def sleep_ms(ms)
    sleep(ms / 1000.0)
    ms
  end

  def crash_process
    Process.exit!(1)
  end

  # Calls back into the BEAM to double a number, demonstrating a reentrant
  # round trip.
  def double_via_callback(n)
    Portals.callback('Elixir.Portals.Fixtures.CallbackTarget', 'double', [n])
  end

  # A callback target the Elixir side invokes; while running (still inside
  # the BEAM-side callback handler) it reports the reentrancy depth the BEAM
  # echoed back on this nested CALL.
  def nested_call_then_callback(_conn_marker, n)
    { 'depth_seen' => Portals.current_callback_depth, 'doubled' => n * 2 }
  end

  def callback_depth_probe = Portals.current_callback_depth

  def deadline_probe = Portals.current_deadline_ms

  def message_to_caller(pid, value)
    Portals.send_message(pid, value)
    'sent'
  end

  def raise_callback_error
    Portals.callback('Elixir.Portals.Fixtures.CallbackTarget', 'boom', [])
  end

  # Value-model probes: proves the Erlang extensions survive a round trip
  # through Ruby untouched.
  def echo_term(value) = value

  def describe_term(value) = value.class.name

  def make_tuple(items) = Portals::Tuple.new(items)

  def make_atom(text) = text.to_sym

  # Cooperative cancellation: polls the flag the CANCEL frame raises.
  def cancellable(ms)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + (ms / 1000.0)
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      return 'cancelled' if Portals.cancelled?

      sleep 0.005
    end
    'completed'
  end

  # -- Streaming targets ------------------------------------------------

  # Echo every inbound chunk back out, then terminate with a count.
  stream_handler def echo_stream(stream)
    count = 0
    while (chunk = stream.recv)
      stream.send(chunk)
      count += 1
    end
    count
  end

  # Produce `count` chunks of `size` bytes each, blocking on the BEAM's
  # credit window.
  stream_handler def produce_stream(stream, count, size)
    payload = 'x' * size
    count.times { stream.send(payload, timeout: 10) }
    stream.half_close
    count
  end

  # Consume everything the BEAM sends, optionally slowly.
  stream_handler def drain_stream(stream, delay_ms = 0)
    chunks = 0
    total = 0
    while (chunk = stream.recv)
      chunks += 1
      total += chunk.bytesize
      sleep(delay_ms / 1000.0) if delay_ms.positive?
    end
    { 'chunks' => chunks, 'bytes' => total }
  end

  # Never consume inbound chunks: the BEAM's sender must block on the credit
  # window rather than grow BEAM memory.
  stream_handler def never_consume(_stream, hold_ms)
    sleep(hold_ms / 1000.0)
    'held'
  end

  # Close only the worker's sending direction immediately, then keep
  # consuming — proving half-close is per-direction.
  stream_handler def half_close_then_drain(stream)
    stream.half_close
    chunks = 0
    chunks += 1 while stream.recv
    chunks
  end

  # Keep a stream open (and a stream-pool thread busy) without doing
  # anything, for unary/stream fairness tests.
  stream_handler def hold_stream(_stream, hold_ms)
    sleep(hold_ms / 1000.0)
    'done'
  end
end
