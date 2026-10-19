# frozen_string_literal: true

# Structured remote-error mapping (FR-4). Every uncaught exception raised by
# a called function becomes an `ERROR` frame carrying language, exception
# class, message, and a normalized, bounded backtrace — never a raw
# marshalled object. The wire shape matches `%Portals.Error{}`:
# `kind`/`message`/`details`/`remote`/`stacktrace`.
module Portals
  module Errors
    MAX_STACK_FRAMES = 64
    MAX_MESSAGE_SIZE = 4096

    module_function

    def build_error_map(exception)
      message = text(exception.message)
      message = message.byteslice(0, MAX_MESSAGE_SIZE).scrub if message.bytesize > MAX_MESSAGE_SIZE

      frames = (exception.backtrace || []).last(MAX_STACK_FRAMES).map { |frame| text(frame) }

      {
        'kind' => 'remote',
        'message' => message.empty? ? exception.class.name : message,
        'details' => {},
        'remote' => {
          'language' => 'ruby',
          'exception_type' => exception.class.name
        },
        'stacktrace' => frames
      }
    end

    # Ruby builds exception messages (and backtraces) as BINARY strings,
    # which the codec would send as MessagePack `bin`; error text must be
    # `str`, so reinterpret it as UTF-8 and replace any invalid bytes.
    def text(value)
      value.to_s.dup.force_encoding(Encoding::UTF_8).scrub
    end

    # A terminal `overload` error, used when the worker is at its advertised
    # stream or concurrency capacity.
    def overload_error_map(message)
      {
        'kind' => 'overload',
        'message' => message,
        'details' => {},
        'remote' => { 'language' => 'ruby' }
      }
    end

    def protocol_error_map(message)
      {
        'kind' => 'protocol',
        'message' => message,
        'details' => {},
        'remote' => { 'language' => 'ruby' }
      }
    end
  end
end
