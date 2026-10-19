# frozen_string_literal: true

require_relative 'protocol'
require_relative 'msgpack_codec'
require_relative 'etf_codec'

# The wire codec this worker speaks, chosen by the BEAM through the
# `PORTALS_CODEC` environment variable (protocol/v1.md §5.4): `etf` (the
# default when unset) or `msgpack`. Read once, when the SDK is loaded; any
# other value refuses to start. Every frame in both directions, `HELLO`
# included, goes through it. Handlers never see it: values arrive and leave
# as the same Ruby types under either.
module Portals
  module Codec
    CODECS = { 'etf' => EtfCodec, 'msgpack' => MsgpackCodec }.freeze

    # The codec module for a `PORTALS_CODEC` value.
    def self.for_name(name)
      CODECS.fetch(name) do
        raise ArgumentError,
              "PORTALS_CODEC=#{name.inspect} is not a codec this SDK speaks (#{CODECS.keys.join(', ')})"
      end
    end

    NAME = ENV.fetch('PORTALS_CODEC', 'etf')
    IMPL = for_name(NAME)
    DecodeError = IMPL::DecodeError

    module_function

    # Encode a frame envelope (an Array) to bytes with the selected codec.
    def encode(envelope, limits = Protocol::DEFAULT_LIMITS) = IMPL.encode(envelope, limits)

    # Decode bytes to `[envelope, rest]` with the selected codec.
    def decode(data, limits = Protocol::DEFAULT_LIMITS) = IMPL.decode(data, limits)
  end
end
