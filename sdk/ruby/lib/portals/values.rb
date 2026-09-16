# frozen_string_literal: true

# Host-language representations of the Erlang-specific value extensions
# (`protocol/v1.md` section 5.1). Ruby has no tuples, no cons-cell lists,
# and cannot construct or interpret PIDs/references, so those are opaque
# wrapper types. Erlang atoms map onto Ruby Symbols, which §5.3 explicitly
# permits for hosts without a persistent atom table.
module Portals
  # An Erlang tuple. Ruby's Array is a list, so tuples need their own type
  # to round-trip back to the BEAM as tuples.
  class Tuple
    attr_reader :items

    def initialize(*items)
      @items = items.length == 1 && items[0].is_a?(Array) ? items[0] : items
      freeze
    end

    def self.[](*items)
      new(items)
    end

    def to_a = @items
    def size = @items.length
    def [](index) = @items[index]
    def ==(other) = other.is_a?(Tuple) && other.items == @items
    alias eql? ==
    def hash = [Tuple, @items].hash
    def inspect = "Portals::Tuple#{@items.inspect}"
  end

  # An opaque local or distributed Erlang PID. A trusted worker may store
  # and echo it back (e.g. as a `MESSAGE` target) but must never attempt to
  # construct or interpret its bytes.
  class Pid
    attr_reader :raw

    def initialize(raw)
      @raw = raw.dup.force_encoding(Encoding::BINARY).freeze
      freeze
    end

    def ==(other) = other.is_a?(Pid) && other.raw == @raw
    alias eql? ==
    def hash = [Pid, @raw].hash
    def inspect = "#Portals::Pid<#{@raw.unpack1('H*')}>"
  end

  # An opaque Erlang reference. Same opacity rules as `Pid`.
  class Reference
    attr_reader :raw

    def initialize(raw)
      @raw = raw.dup.force_encoding(Encoding::BINARY).freeze
      freeze
    end

    def ==(other) = other.is_a?(Reference) && other.raw == @raw
    alias eql? ==
    def hash = [Reference, @raw].hash
    def inspect = "#Portals::Reference<#{@raw.unpack1('H*')}>"
  end

  # An Erlang improper list `[items | tail]`, which Ruby's Array cannot
  # represent.
  class ImproperList
    attr_reader :items, :tail

    def initialize(items, tail)
      @items = items
      @tail = tail
      freeze
    end

    def ==(other) = other.is_a?(ImproperList) && other.items == @items && other.tail == @tail
    alias eql? ==
    def hash = [ImproperList, @items, @tail].hash
    def inspect = "Portals::ImproperList(#{@items.inspect} | #{@tail.inspect})"
  end

  # Wrapper forcing MessagePack `bin` encoding for a String that happens to
  # carry a text encoding (protocol/v1.md §5.2). Decoded `bin` payloads come
  # back as BINARY-encoded Strings, which re-encode as `bin` without a
  # wrapper; this exists for the explicit case.
  class Bin
    attr_reader :data

    def initialize(data)
      @data = data.dup.force_encoding(Encoding::BINARY).freeze
      freeze
    end

    def ==(other) = other.is_a?(Bin) && other.data == @data
    alias eql? ==
    def hash = [Bin, @data].hash
  end

  # Forces MessagePack float64 encoding for an integral Ruby value.
  class Float64
    attr_reader :value

    def initialize(value)
      @value = value.to_f
      freeze
    end

    def ==(other) = other.is_a?(Float64) && other.value == @value
    alias eql? ==
    def hash = [Float64, @value].hash
  end
end
