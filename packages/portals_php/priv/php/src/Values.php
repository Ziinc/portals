<?php

declare(strict_types=1);

namespace Portals;

/*
 * Host-language representations of the value model (protocol/v1.md §5).
 *
 * PHP has no atom table, no tuples, no cons-cell lists, cannot construct or
 * interpret PIDs/references, has a single `string` type for both text and
 * bytes, uses one `array` type for both lists and maps, and has no native
 * arbitrary-precision integers. These wrapper types fill each gap so every
 * decoded term re-encodes exactly as it was received. All of them compare
 * structurally with `==`.
 */

/** An Erlang atom. Decoded as text: PHP has no atom table to exhaust (§5.3). */
final class Atom implements \Stringable
{
    public function __construct(public readonly string $name)
    {
    }

    public function __toString(): string
    {
        return $this->name;
    }
}

/** An Erlang tuple; PHP arrays are lists, so tuples need their own type. */
final class Tuple implements \Countable, \IteratorAggregate, \ArrayAccess
{
    /** @var list<mixed> */
    public readonly array $items;

    public function __construct(array $items)
    {
        $this->items = array_values($items);
    }

    public function count(): int
    {
        return \count($this->items);
    }

    public function getIterator(): \ArrayIterator
    {
        return new \ArrayIterator($this->items);
    }

    public function offsetExists(mixed $offset): bool
    {
        return isset($this->items[$offset]);
    }

    public function offsetGet(mixed $offset): mixed
    {
        return $this->items[$offset];
    }

    public function offsetSet(mixed $offset, mixed $value): void
    {
        throw new \LogicException('Portals\\Tuple is immutable');
    }

    public function offsetUnset(mixed $offset): void
    {
        throw new \LogicException('Portals\\Tuple is immutable');
    }
}

/** An Erlang improper list `[items | tail]`. */
final class ImproperList
{
    public function __construct(public readonly array $items, public readonly mixed $tail)
    {
    }
}

/**
 * An opaque local or distributed Erlang PID. A trusted worker may store and
 * echo it back (e.g. as a `MESSAGE` target) but must never attempt to
 * construct or interpret its bytes.
 */
final class Pid
{
    public function __construct(public readonly string $raw)
    {
    }
}

/** An opaque Erlang reference. Same opacity rules as `Pid`. */
final class Reference
{
    public function __construct(public readonly string $raw)
    {
    }
}

/**
 * Raw bytes (`%Portals.Codec.Bin{}`: MessagePack `bin`, §5.2, or the
 * struct itself under ETF, §5.4). PHP strings are byte strings, so a plain
 * string always encodes as text; wrap a payload in `Bin` to send bytes.
 * Decoded byte payloads are always returned as `Bin`.
 */
final class Bin implements \Stringable
{
    public function __construct(public readonly string $data)
    {
    }

    public function __toString(): string
    {
        return $this->data;
    }
}

/**
 * An integer outside PHP's signed 64-bit range: a uint64 above
 * `PHP_INT_MAX` or an Erlang bigint. Stored as sign + big-endian magnitude
 * (no GMP/BCMath needed). Integers that fit in a PHP `int` are always
 * decoded as `int`; `BigInt::of()` normalises the same way.
 */
final class BigInt implements \Stringable
{
    public readonly bool $negative;
    /** Big-endian magnitude, no leading zero bytes ("" is zero). */
    public readonly string $magnitude;

    public function __construct(bool $negative, string $magnitude)
    {
        $magnitude = ltrim($magnitude, "\0");
        $this->negative = $negative && $magnitude !== '';
        $this->magnitude = $magnitude;
    }

    /** Normalise: an `int` when it fits, otherwise a `BigInt`. */
    public static function of(bool $negative, string $magnitude): int|self
    {
        $big = new self($negative, $magnitude);
        return $big->fitsInt() ? $big->toInt() : $big;
    }

    /** Parse a base-10 integer string of any size. */
    public static function fromDecimal(string $text): int|self
    {
        if (!preg_match('/^([+-]?)(\d+)$/', $text, $m)) {
            throw new \InvalidArgumentException("not an integer: {$text}");
        }
        $bytes = [];
        foreach (str_split(ltrim($m[2], '0')) as $digit) {
            // bytes = bytes * 10 + digit, little-endian base 256.
            $carry = (int) $digit;
            foreach ($bytes as $i => $byte) {
                $value = $byte * 10 + $carry;
                $bytes[$i] = $value & 0xFF;
                $carry = $value >> 8;
            }
            while ($carry > 0) {
                $bytes[] = $carry & 0xFF;
                $carry >>= 8;
            }
        }
        return self::of($m[1] === '-', pack('C*', ...array_reverse($bytes)));
    }

    public function fitsInt(): bool
    {
        $n = \strlen($this->magnitude);
        if ($n < 8) {
            return true;
        }
        if ($n > 8) {
            return false;
        }
        $first = \ord($this->magnitude[0]);
        if ($first < 0x80) {
            return true;
        }
        return $this->negative && $this->magnitude === "\x80" . str_repeat("\0", 7);
    }

    /** True for 0 <= value < 2^64 (encodable as MessagePack uint64). */
    public function fitsUint64(): bool
    {
        return !$this->negative && \strlen($this->magnitude) <= 8;
    }

    public function toInt(): int
    {
        if (!$this->fitsInt()) {
            throw new \OverflowException("{$this} does not fit in a PHP int");
        }
        if ($this->negative && $this->magnitude === "\x80" . str_repeat("\0", 7)) {
            return PHP_INT_MIN;
        }
        $value = 0;
        foreach (unpack('C*', $this->magnitude) ?: [] as $byte) {
            $value = ($value << 8) | $byte;
        }
        return $this->negative ? -$value : $value;
    }

    public function __toString(): string
    {
        $bytes = array_values(unpack('C*', $this->magnitude) ?: []);
        if ($bytes === []) {
            return '0';
        }
        $digits = '';
        while ($bytes !== []) {
            // Long division of the base-256 number by 10.
            $remainder = 0;
            $quotient = [];
            foreach ($bytes as $byte) {
                $value = ($remainder << 8) | $byte;
                $q = intdiv($value, 10);
                $remainder = $value % 10;
                if ($quotient !== [] || $q !== 0) {
                    $quotient[] = $q;
                }
            }
            $digits .= (string) $remainder;
            $bytes = $quotient;
        }
        return ($this->negative ? '-' : '') . strrev($digits);
    }
}

/**
 * A map (string keys only, under either codec, §5). Decoded maps are
 * `Map`s rather than PHP arrays so an empty map, or one whose keys look
 * numeric, never comes back to the BEAM as a list. Reads like an array (`$map['key']`,
 * `foreach`, `count`). When encoding, a plain PHP array that is not a list
 * (`array_is_list`) is also sent as a map.
 */
final class Map implements \Countable, \IteratorAggregate, \ArrayAccess, \JsonSerializable
{
    /** @var array<string, mixed> */
    private array $entries = [];

    public function __construct(iterable $entries = [])
    {
        foreach ($entries as $key => $value) {
            $this->entries[(string) $key] = $value;
        }
    }

    public function toArray(): array
    {
        return $this->entries;
    }

    public function count(): int
    {
        return \count($this->entries);
    }

    public function getIterator(): \Iterator
    {
        // PHP arrays coerce numeric-string keys to ints; yield them as the
        // strings they were on the wire.
        foreach ($this->entries as $key => $value) {
            yield (string) $key => $value;
        }
    }

    public function offsetExists(mixed $offset): bool
    {
        return \array_key_exists((string) $offset, $this->entries);
    }

    public function offsetGet(mixed $offset): mixed
    {
        return $this->entries[(string) $offset] ?? null;
    }

    public function offsetSet(mixed $offset, mixed $value): void
    {
        if ($offset === null) {
            throw new \InvalidArgumentException('Portals\\Map keys must be strings');
        }
        $this->entries[(string) $offset] = $value;
    }

    public function offsetUnset(mixed $offset): void
    {
        unset($this->entries[(string) $offset]);
    }

    public function jsonSerialize(): mixed
    {
        return (object) $this->entries;
    }
}
