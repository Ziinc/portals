# frozen_string_literal: true

# Frame tag registry and default limits for the Portals v1 protocol.
#
# Mirrors `lib/portals/protocol.ex` and `sdk/python/portals/protocol.py`.
# See `protocol/v1.md` for the authoritative specification.
module Portals
  module Protocol
    PROTOCOL_VERSION = 1

    HELLO = 1
    READY = 2
    CALL = 3
    RETURN = 4
    ERROR = 5
    CANCEL = 6
    CALLBACK = 7
    CALLBACK_RETURN = 8
    CALLBACK_ERROR = 9
    MESSAGE = 10
    STREAM_DATA = 11
    CREDIT = 12
    HALF_CLOSE = 13
    PING = 14
    PONG = 15
    SHUTDOWN = 16

    FRAME_NAMES = {
      HELLO => 'hello',
      READY => 'ready',
      CALL => 'call',
      RETURN => 'return',
      ERROR => 'error',
      CANCEL => 'cancel',
      CALLBACK => 'callback',
      CALLBACK_RETURN => 'callback_return',
      CALLBACK_ERROR => 'callback_error',
      MESSAGE => 'message',
      STREAM_DATA => 'stream_data',
      CREDIT => 'credit',
      HALF_CLOSE => 'half_close',
      PING => 'ping',
      PONG => 'pong',
      SHUTDOWN => 'shutdown'
    }.freeze

    DEFAULT_LIMITS = {
      'max_frame_size' => 16 * 1024 * 1024,
      'max_nesting_depth' => 32,
      'max_collection_length' => 65_536,
      'max_metadata_size' => 65_536,
      'max_callback_depth' => 16,
      'max_in_flight_callbacks' => 256,
      'max_in_flight_requests' => 4096,
      'max_stream_byte_credit' => 4 * 1024 * 1024,
      'max_queued_stream_frames' => 1024
    }.freeze
  end
end
