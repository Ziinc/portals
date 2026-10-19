# frozen_string_literal: true

require_relative 'protocol'
require_relative 'values'
require_relative 'msgpack_codec'
require_relative 'errors'
require_relative 'transport'
require_relative 'streams'

# The Ruby worker runtime: connects to the BEAM's Unix socket, completes the
# exact-version handshake, and dispatches `CALL` frames to arbitrary
# module/function targets concurrently.
#
#     require 'portals'
#     Portals::Worker.new.run
#
# The socket reader is a dedicated thread independent of call execution
# (each `CALL` is handed to a bounded thread pool), so a slow or blocked
# handler can never stall reading further frames or responding to other
# in-flight calls.
#
# Fully reentrant callbacks (protocol/v1.md §8): a handler running inside a
# `CALL` may call back into the BEAM with `Portals.callback(...)`, which
# blocks the *handler's own thread* (never the reader thread), so a nested
# `CALL` dispatched back into this same worker while the callback is
# outstanding is still served by another pool thread.
module Portals
  # Raised by `Portals.callback` when the BEAM-side handler fails.
  class RemoteError < StandardError
    attr_reader :error_map

    def initialize(error_map)
      @error_map = error_map
      super(error_map['message'] || 'callback failed')
    end
  end

  class ProtocolError < StandardError; end

  class CallbackTimeout < StandardError; end

  # Mixin marking module functions as streaming targets:
  #
  #     module BenchWorker
  #       extend Portals::StreamHandlers
  #       stream_handler def echo_stream(stream) ... end
  #     end
  module StreamHandlers
    def stream_handler(name)
      portals_stream_handlers << name.to_s
      name
    end

    def portals_stream_handlers
      @portals_stream_handlers ||= []
    end

    def portals_stream_handler?(name)
      portals_stream_handlers.include?(name.to_s)
    end
  end

  # Cooperative cancellation signal for one in-flight unary CALL. Handlers
  # poll it with `Portals.cancelled?`; Portals never force-kills a handler.
  class CancellationFlag
    def initialize
      @cancelled = false
      @mutex = Mutex.new
    end

    def cancel! = @mutex.synchronize { @cancelled = true }
    def cancelled? = @mutex.synchronize { @cancelled }
  end

  # Minimal fixed-size thread pool. A bounded pool is what makes the
  # advertised `max_concurrency`/`max_streams` real rather than aspirational.
  class ThreadPool
    def initialize(size, name)
      @queue = Queue.new
      @threads = Array.new(size) do |i|
        Thread.new do
          Thread.current.name = "#{name}-#{i}"
          while (job = @queue.pop)
            begin
              job.call
            rescue StandardError => e
              warn "portals worker: pool job raised #{e.class}: #{e.message}"
            end
          end
        end
      end
    end

    def submit(&block) = @queue.push(block)

    def shutdown
      @threads.length.times { @queue.push(nil) }
      @threads.each { |thread| thread.join(2) }
    end
  end

  class Worker
    DEFAULT_MAX_CONCURRENCY = 16
    DEFAULT_MAX_STREAMS = 8

    class << self
      attr_accessor :active
    end

    attr_reader :limits

    def initialize(max_concurrency: DEFAULT_MAX_CONCURRENCY,
                   max_streams: DEFAULT_MAX_STREAMS,
                   socket_path: nil,
                   transport: :unix,
                   modules: {},
                   protocol_version: Protocol::PROTOCOL_VERSION,
                   logger: nil)
      @max_concurrency = max_concurrency
      @max_streams = max_streams
      @socket_path = socket_path
      @transport_mode = transport.to_sym
      @modules = {}
      modules.each { |name, mod| register(name, mod) }
      # Overridable strictly so the version-mismatch diagnostics can be
      # exercised end to end; real workers always send the SDK's version.
      @protocol_version = protocol_version
      @logger = logger || self.class.default_logger

      @limits = Protocol::DEFAULT_LIMITS.dup
      @streams = {}
      @streams_mutex = Mutex.new
      @pending_unary = {}
      @shutdown = false

      @callback_id = 0
      @callback_mutex = Mutex.new
      @pending_callbacks = {}
    end

    # Logging goes to a file or a callable, never over the RPC protocol.
    # `PORTALS_LOG_FILE` picks a file; otherwise stderr, which the BEAM
    # captures out of band.
    def self.default_logger
      path = ENV['PORTALS_LOG_FILE']
      return ->(message) { warn(message) } unless path

      file = File.open(path, 'a')
      file.sync = true
      ->(message) { file.puts(message) }
    end

    # Register a module under the name the BEAM will use in `CALL`.
    def register(name, mod)
      @modules[name.to_s] = mod
      self
    end

    def run
      @conn =
        if @transport_mode == :stdio
          FramedStdio.new
        else
          FramedSocket.connect_unix(@socket_path || Portals.socket_path_from_argv)
        end

      handshake

      @pool = ThreadPool.new(@max_concurrency, 'portals-call')
      @stream_pool = @max_streams.positive? ? ThreadPool.new(@max_streams, 'portals-stream') : nil
      self.class.active = self

      begin
        until @shutdown
          payload =
            begin
              @conn.recv_frame
            rescue ConnectionClosed
              break
            end
          break if payload.nil?

          handle_frame(payload)
        end
      ensure
        self.class.active = nil if self.class.active.equal?(self)
        cancel_all_streams
        @pool.shutdown
        @stream_pool&.shutdown
        @conn.close
      end
    end

    # -- Handshake ------------------------------------------------------

    def handshake
      hello = [
        Protocol::HELLO,
        @protocol_version,
        "ruby#{RUBY_VERSION}",
        @max_concurrency,
        @max_streams,
        []
      ]
      @conn.send_frame(MsgpackCodec.encode(hello, @limits))

      payload = @conn.recv_frame
      raise ConnectionClosed, 'connection closed during handshake' if payload.nil?

      envelope, rest = MsgpackCodec.decode(payload, @limits)
      raise ProtocolError, 'trailing bytes after READY' unless rest.empty?

      tag = envelope[0]
      raise ProtocolError, "expected READY, got frame tag #{tag}" unless tag == Protocol::READY

      _tag, version, limits = envelope
      unless version == Protocol::PROTOCOL_VERSION
        raise ProtocolError,
              "protocol version mismatch: worker=#{Protocol::PROTOCOL_VERSION} beam=#{version}"
      end

      @limits = @limits.merge(limits)
    end

    # -- Reentrant callbacks and messaging --------------------------------

    def call_callback(mod, function, args, timeout: nil)
      depth = Portals.current_callback_depth + 1
      id = @callback_mutex.synchronize { @callback_id += 1 }
      entry = { mutex: Mutex.new, cond: ConditionVariable.new, done: false }
      @callback_mutex.synchronize { @pending_callbacks[id] = entry }

      send_envelope([Protocol::CALLBACK, id, mod, function, args, depth])

      ok, value, error = entry[:mutex].synchronize do
        unless entry[:done]
          entry[:cond].wait(entry[:mutex], timeout)
          unless entry[:done]
            @callback_mutex.synchronize { @pending_callbacks.delete(id) }
            raise CallbackTimeout, "callback #{mod}.#{function} timed out"
          end
        end

        [entry[:ok], entry[:value], entry[:error]]
      end

      raise RemoteError, error unless ok

      value
    end

    def send_message(target_pid, value)
      send_envelope([Protocol::MESSAGE, target_pid, value])
    end

    def resolve_callback(id, ok, value: nil, error: nil)
      entry = @callback_mutex.synchronize { @pending_callbacks.delete(id) }
      if entry.nil?
        log("portals worker: unknown callback_id #{id} in response")
        return
      end

      entry[:mutex].synchronize do
        entry[:ok] = ok
        entry[:value] = value
        entry[:error] = error
        entry[:done] = true
        entry[:cond].broadcast
      end
    end

    # -- Frame dispatch ---------------------------------------------------

    def handle_frame(payload)
      begin
        envelope, rest = MsgpackCodec.decode(payload, @limits)
      rescue MsgpackCodec::DecodeError => e
        log("portals worker: dropping malformed frame: #{e.reason.inspect}")
        return
      end

      unless rest.empty?
        log('portals worker: dropping frame with trailing bytes')
        return
      end

      tag = envelope[0]
      frame_size = payload.bytesize + FRAME_PREFIX_BYTES

      case tag
      when Protocol::CALL then submit_call(envelope[1..])
      when Protocol::CANCEL then cancel_request(envelope[1])
      when Protocol::STREAM_DATA then handle_stream_data(envelope[1], envelope[2], frame_size)
      when Protocol::CREDIT
        fields = envelope[1..]
        stream = find_stream(fields[0])
        stream&.add_send_credit(fields[1], fields.length > 2 ? fields[2] : 1)
      when Protocol::HALF_CLOSE then find_stream(envelope[1])&.peer_half_closed
      when Protocol::CALLBACK_RETURN then resolve_callback(envelope[1], true, value: envelope[2])
      when Protocol::CALLBACK_ERROR then resolve_callback(envelope[1], false, error: envelope[2])
      when Protocol::PING then send_envelope([Protocol::PONG, envelope[1]])
      when Protocol::PONG then nil
      when Protocol::SHUTDOWN then @shutdown = true
      else
        log("portals worker: ignoring unsupported frame tag #{tag}")
      end
    end

    # -- Dispatch ---------------------------------------------------------

    # Route a CALL to the unary pool, or — when its target was declared with
    # `stream_handler` — to the separate stream pool with a `Stream` bound to
    # the call's request_id.
    def submit_call(fields)
      request_id, module_name, function_name = fields[0], fields[1], fields[2]

      unless stream_target?(module_name, function_name)
        @pool.submit { dispatch_call(fields) }
        return
      end

      if @stream_pool.nil?
        send_envelope([Protocol::ERROR, request_id,
                       Errors.overload_error_map('worker advertises no streams')])
        return
      end

      stream = nil
      @streams_mutex.synchronize do
        if @streams.size >= @max_streams
          stream = :overload
        else
          stream = Stream.new(
            request_id,
            @limits['max_stream_byte_credit'],
            @limits['max_queued_stream_frames'],
            ->(bytes) { @conn.send_frame(bytes) },
            ->(envelope) { MsgpackCodec.encode(envelope, @limits) }
          )
          @streams[request_id] = stream
        end
      end

      if stream == :overload
        send_envelope([Protocol::ERROR, request_id, Errors.overload_error_map('max_streams exceeded')])
        return
      end

      grant = stream.initial_grant
      send_envelope([Protocol::CREDIT, request_id, grant, 0]) if grant.positive?

      @stream_pool.submit { dispatch_stream_call(stream, fields) }
    end

    def dispatch_stream_call(stream, fields)
      request_id = fields[0]
      args = fields[3] || []

      begin
        mod = resolve_module(fields[1])
        result = mod.public_send(fields[2], stream, *args)
      rescue StandardError => e
        release_stream(request_id)
        send_envelope([Protocol::ERROR, request_id, Errors.build_error_map(e)]) unless stream.cancelled?
        return
      end

      stream.half_close
      release_stream(request_id)
      send_envelope([Protocol::RETURN, request_id, result]) unless stream.cancelled?
    end

    def dispatch_call(fields)
      request_id, module_name, function_name, args = fields[0], fields[1], fields[2], fields[3]
      deadline_ms = fields[4]
      depth = fields[5] || 0

      flag = CancellationFlag.new
      @streams_mutex.synchronize { @pending_unary[request_id] = flag }

      Thread.current[:portals_callback_depth] = depth
      Thread.current[:portals_deadline_ms] = deadline_ms
      Thread.current[:portals_cancellation] = flag

      begin
        mod = resolve_module(module_name)
        result = mod.public_send(function_name, *(args || []))
      rescue StandardError, ScriptError => e
        send_envelope([Protocol::ERROR, request_id, Errors.build_error_map(e)])
        return
      ensure
        @streams_mutex.synchronize { @pending_unary.delete(request_id) }
        Thread.current[:portals_callback_depth] = 0
        Thread.current[:portals_deadline_ms] = nil
        Thread.current[:portals_cancellation] = nil
      end

      send_envelope([Protocol::RETURN, request_id, result])
    end

    # Resolve a wire module name to a Ruby object: an explicitly registered
    # module wins; otherwise the name is treated as a constant path, and
    # failing that as a requirable file whose camelized basename names the
    # module (`"bench_worker"` -> `BenchWorker`).
    def resolve_module(name)
      key = name.to_s
      return @modules[key] if @modules.key?(key)

      mod =
        begin
          Object.const_get(key)
        rescue NameError
          require key
          Object.const_get(camelize(key))
        end

      @modules[key] = mod
      mod
    end

    def stream_target?(module_name, function_name)
      mod = resolve_module(module_name)
      mod.respond_to?(:portals_stream_handler?) && mod.portals_stream_handler?(function_name)
    rescue StandardError, ScriptError
      # An unresolvable target is reported properly by the unary path.
      false
    end

    def camelize(name)
      name.split('/').last.split('_').map { |part| part[0].upcase + part[1..].to_s }.join
    end

    # -- Streaming --------------------------------------------------------

    def find_stream(stream_id)
      @streams_mutex.synchronize { @streams[stream_id] }
    end

    def release_stream(stream_id)
      @streams_mutex.synchronize { @streams.delete(stream_id) }
    end

    def handle_stream_data(stream_id, chunk, frame_size)
      stream = find_stream(stream_id)
      return if stream.nil?

      begin
        stream.record_inbound(chunk, frame_size)
      rescue StreamProtocolError => e
        # A peer that exceeds its allowance loses only that stream.
        stream.cancel
        release_stream(stream_id)
        send_envelope([Protocol::ERROR, stream_id, Errors.protocol_error_map(e.message)])
      end
    end

    # `CANCEL` shares the `request_id` space with streams: it cancels the
    # stream outright, or raises the cooperative cancellation flag for an
    # in-flight unary call (protocol/v1.md §7 — cancellation is
    # cooperative, never a forced kill).
    def cancel_request(request_id)
      stream = find_stream(request_id)
      if stream
        stream.cancel
        release_stream(request_id)
        return
      end

      flag = @streams_mutex.synchronize { @pending_unary[request_id] }
      flag&.cancel!
    end

    def cancel_all_streams
      streams = @streams_mutex.synchronize do
        values = @streams.values
        @streams.clear
        values
      end
      streams.each(&:cancel)
    end

    def send_envelope(envelope)
      @conn.send_frame(MsgpackCodec.encode(envelope, @limits))
    rescue ConnectionClosed, IOError, SystemCallError => e
      log("portals worker: send failed: #{e.class}: #{e.message}")
    end

    def log(message) = @logger.call(message)
  end

  module_function

  # Invoke a BEAM callback from within a `CALL` handler and block for its
  # result. Requires a running `Worker` in this process.
  def callback(mod, function, args = [], timeout: nil)
    worker = Worker.active
    raise 'Portals.callback called with no active Worker in this process' if worker.nil?

    worker.call_callback(mod, function, args, timeout: timeout)
  end

  # Send a value to a BEAM PID (typically one received as a `CALL`
  # argument). Fire-and-forget.
  def send_message(target_pid, value)
    worker = Worker.active
    raise 'Portals.send_message called with no active Worker in this process' if worker.nil?

    worker.send_message(target_pid, value)
  end

  # The reentrancy depth of the `CALL` currently executing on this thread.
  def current_callback_depth = Thread.current[:portals_callback_depth] || 0

  # The deadline (in ms) the BEAM attached to the currently executing CALL,
  # or nil. Handlers use it to bound their own work cooperatively.
  def current_deadline_ms = Thread.current[:portals_deadline_ms]

  # Cooperative cancellation: true once the BEAM sent `CANCEL` for the call
  # currently executing on this thread.
  def cancelled?
    flag = Thread.current[:portals_cancellation]
    flag ? flag.cancelled? : false
  end
end
