<?php

declare(strict_types=1);

namespace Portals;

/**
 * Pure-PHP Erlang External Term Format codec (protocol/v1.md §5.4), the
 * PHP side of `Portals.Codec.ETF` and the default wire codec (see `Codec`).
 * Like `MsgpackCodec` it needs nothing beyond PHP core and `mbstring`.
 *
 * Values map to exactly the PHP types `MsgpackCodec` produces, so handlers
 * never see which codec is in use: binaries are `string` (UTF-8), the
 * `%Portals.Codec.Bin{}` struct is `Bin` (and `Bin` encodes as that
 * struct), the atoms `nil`/`true`/`false` are `null`/`true`/`false` and any
 * other atom is `Atom`, tuples are `Tuple`, maps are string-keyed `Map`s,
 * improper lists are `ImproperList`, integers beyond 64 bits are `BigInt`,
 * and PIDs and references are opaque `Pid`/`Reference` holding their own
 * ETF bytes, written back verbatim.
 */
final class EtfCodec
{
    public const VERSION = 131;

    public const NEW_FLOAT = 70;
    public const BIT_BINARY = 77;
    public const NEW_PID = 88;
    public const NEWER_REFERENCE = 90;
    public const SMALL_INTEGER = 97;
    public const INTEGER = 98;
    public const ATOM = 100;
    public const PID = 103;
    public const SMALL_TUPLE = 104;
    public const LARGE_TUPLE = 105;
    public const NIL = 106;
    public const STRING = 107;
    public const LIST = 108;
    public const BINARY = 109;
    public const SMALL_BIG = 110;
    public const LARGE_BIG = 111;
    public const NEW_REFERENCE = 114;
    public const SMALL_ATOM = 115;
    public const MAP = 116;
    public const ATOM_UTF8 = 118;
    public const SMALL_ATOM_UTF8 = 119;

    /** How `Bin` is encoded: `%Portals.Codec.Bin{data: ...}`, up to the data binary itself. */
    private const BIN_PREFIX = "\x74\x00\x00\x00\x02"
        . "\x77\x0A__struct__"
        . "\x77\x18Elixir.Portals.Codec.Bin"
        . "\x77\x04data";

    private const SPECIAL_ATOMS = ['nil' => null, 'true' => true, 'false' => false];

    // -- Encoding -----------------------------------------------------------

    public static function encode(mixed $envelope, array $limits = Protocol::DEFAULT_LIMITS): string
    {
        $out = "\x83";
        self::encodeTerm($envelope, $out, 0, $limits);
        if (\strlen($out) > $limits['max_frame_size']) {
            throw new DecodeError('max_size_exceeded', \strlen($out));
        }
        return $out;
    }

    /** Append the encoding of `$term` to `$out` (appending in place keeps encoding linear). */
    private static function encodeTerm(mixed $term, string &$out, int $depth, array $limits): void
    {
        self::checkDepth($depth, $limits);

        if ($term === null) {
            $out .= "\x77\x03nil";
        } elseif ($term === true) {
            $out .= "\x77\x04true";
        } elseif ($term === false) {
            $out .= "\x77\x05false";
        } elseif (\is_int($term)) {
            self::encodeInt($term, $out);
        } elseif (\is_float($term)) {
            $out .= "\x46" . pack('E', $term);
        } elseif (\is_string($term)) {
            $out .= "\x6D" . pack('N', \strlen($term)) . $term;
        } elseif (\is_array($term)) {
            self::checkLength(\count($term), $limits);
            if (array_is_list($term)) {
                self::encodeList($term, $out, $depth, $limits);
            } else {
                self::encodeMap($term, $out, $depth, $limits);
            }
        } elseif ($term instanceof Bin) {
            $out .= self::BIN_PREFIX . "\x6D" . pack('N', \strlen($term->data)) . $term->data;
        } elseif ($term instanceof Map) {
            self::checkLength(\count($term), $limits);
            self::encodeMap($term->toArray(), $out, $depth, $limits);
        } elseif ($term instanceof Atom) {
            self::encodeAtom($term->name, $out);
        } elseif ($term instanceof Pid || $term instanceof Reference) {
            $out .= $term->raw;
        } elseif ($term instanceof Tuple) {
            $n = \count($term->items);
            self::checkLength($n, $limits);
            $out .= $n < 256 ? "\x68" . \chr($n) : "\x69" . pack('N', $n);
            foreach ($term->items as $item) {
                self::encodeTerm($item, $out, $depth + 1, $limits);
            }
        } elseif ($term instanceof ImproperList) {
            self::checkLength(\count($term->items), $limits);
            $out .= "\x6C" . pack('N', \count($term->items));
            foreach ($term->items as $item) {
                self::encodeTerm($item, $out, $depth + 1, $limits);
            }
            self::encodeTerm($term->tail, $out, $depth + 1, $limits);
        } elseif ($term instanceof BigInt) {
            if ($term->fitsInt()) {
                self::encodeInt($term->toInt(), $out);
            } else {
                self::encodeBig($term->negative, strrev($term->magnitude), $out);
            }
        } elseif ($term instanceof \BackedEnum) {
            self::encodeTerm($term->value, $out, $depth, $limits);
        } elseif ($term instanceof \UnitEnum) {
            self::encodeAtom($term->name, $out);
        } elseif ($term instanceof \stdClass || $term instanceof \JsonSerializable) {
            $value = $term instanceof \JsonSerializable ? $term->jsonSerialize() : get_object_vars($term);
            if ($value instanceof \stdClass) {
                $value = get_object_vars($value);
            }
            if (\is_array($value)) {
                self::checkLength(\count($value), $limits);
                self::encodeMap($value, $out, $depth, $limits);
            } else {
                self::encodeTerm($value, $out, $depth, $limits);
            }
        } else {
            throw new DecodeError('invalid_encoding', 'unsupported type ' . get_debug_type($term));
        }
    }

    private static function encodeList(array $items, string &$out, int $depth, array $limits): void
    {
        if ($items !== []) {
            $out .= "\x6C" . pack('N', \count($items));
            foreach ($items as $item) {
                self::encodeTerm($item, $out, $depth + 1, $limits);
            }
        }
        $out .= "\x6A";
    }

    /** Keys are always sent as text, as `MsgpackCodec` (and every other SDK's encoder) does. */
    private static function encodeMap(array $entries, string &$out, int $depth, array $limits): void
    {
        $out .= "\x74" . pack('N', \count($entries));
        foreach ($entries as $key => $value) {
            $key = (string) $key;
            $out .= "\x6D" . pack('N', \strlen($key)) . $key;
            self::encodeTerm($value, $out, $depth + 1, $limits);
        }
    }

    private static function encodeAtom(string $name, string &$out): void
    {
        $n = \strlen($name);
        $out .= ($n < 256 ? "\x77" . \chr($n) : "\x76" . pack('n', $n)) . $name;
    }

    private static function encodeInt(int $n, string &$out): void
    {
        if ($n >= 0 && $n < 256) {
            $out .= "\x61" . \chr($n);
        } elseif ($n >= -2147483648 && $n <= 2147483647) {
            $out .= "\x62" . pack('N', $n & 0xFFFFFFFF);
        } else {
            // -n cannot overflow except for PHP_INT_MIN, whose magnitude is 2^63.
            $magnitude = $n === PHP_INT_MIN ? str_repeat("\0", 7) . "\x80" : rtrim(pack('P', abs($n)), "\0");
            self::encodeBig($n < 0, $magnitude, $out);
        }
    }

    /** `$digits` is the magnitude, least significant byte first. */
    private static function encodeBig(bool $negative, string $digits, string &$out): void
    {
        $n = \strlen($digits);
        $out .= ($n < 256 ? "\x6E" . \chr($n) : "\x6F" . pack('N', $n)) . ($negative ? "\x01" : "\x00") . $digits;
    }

    // -- Decoding -----------------------------------------------------------

    /**
     * Decode one term (version byte included) from the front of `$data`.
     * Returns `[term, rest]`, where `rest` is any bytes left over. A
     * non-array top-level term is wrapped in a one-element list, as in the
     * other SDKs.
     *
     * @return array{0: mixed, 1: string}
     */
    public static function decode(string $data, array $limits = Protocol::DEFAULT_LIMITS): array
    {
        if (\strlen($data) > $limits['max_frame_size']) {
            throw new DecodeError('max_size_exceeded', \strlen($data));
        }
        self::need($data, 1);
        if (\ord($data[0]) !== self::VERSION) {
            throw new DecodeError('invalid_encoding', \ord($data[0]));
        }
        $pos = 1;
        $term = self::decodeTerm($data, $pos, 0, $limits);
        return [\is_array($term) ? $term : [$term], (string) substr($data, $pos)];
    }

    /** Fail with `truncated` unless `$data` holds at least `$end` bytes. */
    private static function need(string $data, int $end): void
    {
        if ($end > \strlen($data)) {
            throw new DecodeError('truncated', \strlen($data));
        }
    }

    /** Read a big-endian unsigned length field of `$size` bytes at `$pos`. */
    private static function lengthAt(string $data, int $pos, int $size): int
    {
        self::need($data, $pos + $size);
        return unpack([1 => 'C', 2 => 'n', 4 => 'N'][$size], $data, $pos)[1];
    }

    private static function decodeTerm(string $data, int &$pos, int $depth, array $limits): mixed
    {
        self::checkDepth($depth, $limits);
        self::need($data, $pos + 1);
        $tag = \ord($data[$pos]);

        switch ($tag) {
            case self::SMALL_INTEGER:
                self::need($data, $pos + 2);
                $value = \ord($data[$pos + 1]);
                $pos += 2;
                return $value;
            case self::INTEGER:
                self::need($data, $pos + 5);
                $value = unpack('N', $data, $pos + 1)[1];
                $pos += 5;
                return $value >= 0x80000000 ? $value - 0x100000000 : $value;
            case self::NEW_FLOAT:
                self::need($data, $pos + 9);
                $value = unpack('E', $data, $pos + 1)[1];
                $pos += 9;
                return $value;
            case self::SMALL_ATOM_UTF8:
            case self::ATOM_UTF8:
            case self::SMALL_ATOM:
            case self::ATOM:
                $name = self::decodeAtom($data, $pos);
                return \array_key_exists($name, self::SPECIAL_ATOMS) ? self::SPECIAL_ATOMS[$name] : new Atom($name);
            case self::BINARY:
                return self::text(self::binary($data, $pos));
            case self::NIL:
                $pos += 1;
                return [];
            case self::LIST:
                $n = self::lengthAt($data, $pos + 1, 4);
                self::checkLength($n, $limits);
                $pos += 5;
                $items = [];
                for ($i = 0; $i < $n; $i++) {
                    $items[] = self::decodeTerm($data, $pos, $depth + 1, $limits);
                }
                self::need($data, $pos + 1);
                if (\ord($data[$pos]) === self::NIL) {
                    $pos += 1;
                    return $items;
                }
                return new ImproperList($items, self::decodeTerm($data, $pos, $depth + 1, $limits));
            case self::STRING:
                // A list of bytes, as a charlist `~c"ab"` arrives under MessagePack.
                $n = self::lengthAt($data, $pos + 1, 2);
                self::checkLength($n, $limits);
                self::need($data, $pos + 3 + $n);
                $items = $n === 0 ? [] : array_values(unpack('C*', substr($data, $pos + 3, $n)));
                $pos += 3 + $n;
                return $items;
            case self::SMALL_TUPLE:
            case self::LARGE_TUPLE:
                $size = $tag === self::SMALL_TUPLE ? 1 : 4;
                $n = self::lengthAt($data, $pos + 1, $size);
                self::checkLength($n, $limits);
                $pos += 1 + $size;
                $items = [];
                for ($i = 0; $i < $n; $i++) {
                    $items[] = self::decodeTerm($data, $pos, $depth + 1, $limits);
                }
                return new Tuple($items);
            case self::MAP:
                return self::decodeMap($data, $pos, $depth, $limits);
            case self::SMALL_BIG:
            case self::LARGE_BIG:
                $size = $tag === self::SMALL_BIG ? 1 : 4;
                $n = self::lengthAt($data, $pos + 1, $size);
                $start = $pos + 1 + $size;
                self::need($data, $start + 1 + $n);
                $negative = $data[$start] !== "\0";
                $pos = $start + 1 + $n;
                return BigInt::of($negative, strrev(substr($data, $start + 1, $n)));
            case self::NEW_PID:
            case self::PID:
                $end = self::skipAtom($data, $pos + 1) + ($tag === self::NEW_PID ? 12 : 9);
                return new Pid(self::rawTerm($data, $pos, $end));
            case self::NEWER_REFERENCE:
            case self::NEW_REFERENCE:
                $n = self::lengthAt($data, $pos + 1, 2);
                $end = self::skipAtom($data, $pos + 3) + ($tag === self::NEWER_REFERENCE ? 4 : 1) + 4 * $n;
                return new Reference(self::rawTerm($data, $pos, $end));
        }

        throw new DecodeError('invalid_encoding', $tag);
    }

    /**
     * A map is a `%Portals.Codec.Bin{}` struct when it has exactly the atom
     * keys `__struct__` (mapped to that module's atom) and `data` (mapped to
     * a binary), in either order. That is decided on the raw keys, so an
     * atom-keyed `data` binary is held as raw bytes until the whole map is
     * read; anywhere else it is text like every other binary. Every other
     * map is string-keyed, as under MessagePack.
     */
    private static function decodeMap(string $data, int &$pos, int $depth, array $limits): Map|Bin
    {
        $n = self::lengthAt($data, $pos + 1, 4);
        self::checkLength($n, $limits);
        $pos += 5;
        $entries = [];
        $rawData = false;
        $binStruct = false;
        for ($i = 0; $i < $n; $i++) {
            $key = self::decodeTerm($data, $pos, $depth + 1, $limits);
            if (\is_string($key)) {
                $entries[$key] = self::decodeTerm($data, $pos, $depth + 1, $limits);
            } elseif ($key instanceof Atom && $key->name === 'data' && self::tagAt($data, $pos) === self::BINARY) {
                $entries['data'] = self::binary($data, $pos);
                $rawData = true;
            } else {
                $value = self::decodeTerm($data, $pos, $depth + 1, $limits);
                if ($key instanceof Atom && $key->name === '__struct__') {
                    $binStruct = $value instanceof Atom && $value->name === 'Elixir.Portals.Codec.Bin';
                }
                $entries[self::keyText($key)] = $value;
            }
        }

        if ($rawData) {
            if ($binStruct && $n === 2 && \count($entries) === 2) {
                return new Bin($entries['data']);
            }
            $entries['data'] = self::text($entries['data']);
        }
        return new Map($entries);
    }

    /** A decoded map key as text, the way the MessagePack encoders stringify keys. */
    private static function keyText(mixed $key): string
    {
        if (\is_string($key) || \is_int($key) || $key instanceof Atom || $key instanceof BigInt) {
            return (string) $key;
        }
        if ($key === null) {
            return ''; // Elixir's to_string(nil)
        }
        if (\is_bool($key)) {
            return $key ? 'true' : 'false';
        }
        throw new DecodeError('invalid_encoding', 'unsupported map key ' . get_debug_type($key));
    }

    private static function tagAt(string $data, int $pos): int
    {
        self::need($data, $pos + 1);
        return \ord($data[$pos]);
    }

    /** Read a `BINARY_EXT` payload as raw bytes and advance past it. */
    private static function binary(string $data, int &$pos): string
    {
        $n = self::lengthAt($data, $pos + 1, 4);
        $start = $pos + 5;
        self::need($data, $start + $n);
        $pos = $start + $n;
        return (string) substr($data, $start, $n);
    }

    /** Binaries decode as text, so they must be valid UTF-8. */
    private static function text(string $bytes): string
    {
        if (!mb_check_encoding($bytes, 'UTF-8')) {
            throw new DecodeError('invalid_encoding', 'binary is not UTF-8');
        }
        return $bytes;
    }

    /** Read any atom encoding at `$pos`, as UTF-8 text, and advance past it. */
    private static function decodeAtom(string $data, int &$pos): string
    {
        $tag = \ord($data[$pos]);
        $size = $tag === self::SMALL_ATOM_UTF8 || $tag === self::SMALL_ATOM ? 1 : 2;
        $n = self::lengthAt($data, $pos + 1, $size);
        $start = $pos + 1 + $size;
        self::need($data, $start + $n);
        $pos = $start + $n;
        $name = (string) substr($data, $start, $n);
        if ($tag === self::SMALL_ATOM || $tag === self::ATOM) {
            // Latin-1: every byte is the code point of the same value.
            return mb_convert_encoding($name, 'UTF-8', 'ISO-8859-1');
        }
        if (!mb_check_encoding($name, 'UTF-8')) {
            throw new DecodeError('invalid_encoding', 'atom is not UTF-8');
        }
        return $name;
    }

    /** Skip the node atom inside a PID or reference; returns the offset after it. */
    private static function skipAtom(string $data, int $pos): int
    {
        $tag = self::tagAt($data, $pos);
        if ($tag !== self::SMALL_ATOM_UTF8 && $tag !== self::ATOM_UTF8 && $tag !== self::SMALL_ATOM && $tag !== self::ATOM) {
            throw new DecodeError('invalid_encoding', $tag);
        }
        self::decodeAtom($data, $pos);
        return $pos;
    }

    /** The bytes of a whole term (tag included) ending at `$end`; advances past it. */
    private static function rawTerm(string $data, int &$pos, int $end): string
    {
        self::need($data, $end);
        $raw = (string) substr($data, $pos, $end - $pos);
        $pos = $end;
        return $raw;
    }

    private static function checkDepth(int $depth, array $limits): void
    {
        if ($depth > $limits['max_nesting_depth']) {
            throw new DecodeError('max_depth_exceeded', $depth);
        }
    }

    private static function checkLength(int $count, array $limits): void
    {
        if ($count > $limits['max_collection_length']) {
            throw new DecodeError('max_length_exceeded', $count);
        }
    }
}
