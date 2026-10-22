# frozen_string_literal: true

# Portals Ruby worker SDK.
#
# Full parity with the reference Python SDK: Unix-socket transport with a
# framed stdio fallback, dependency-free ETF (the default) and MessagePack
# codecs covering the Erlang value types, the exact-version HELLO/READY handshake,
# concurrent arbitrary module/function dispatch, structured error frames,
# reentrant callbacks, PID messaging, and bidirectional streaming with
# byte-credit windows, frame-count caps and per-direction half-close.
#
# See `protocol/v1.md` for the wire protocol.
module Portals
  VERSION = '0.1.0'
end

require_relative 'portals/protocol'
require_relative 'portals/values'
require_relative 'portals/msgpack_codec'
require_relative 'portals/etf_codec'
require_relative 'portals/codec'
require_relative 'portals/errors'
require_relative 'portals/transport'
require_relative 'portals/streams'
require_relative 'portals/worker'
