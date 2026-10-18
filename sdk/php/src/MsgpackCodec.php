<?php

declare(strict_types=1);

namespace Portals;

/**
 * Raised for every codec-level failure, on encode and decode alike: never a
 * generic exception, and never anything that escapes past the offending
 * connection. `$reason` is the documented error class
 * (`truncated`, `invalid_encoding`, `max_length_exceeded`, ...).
 */
final class DecodeError extends \RuntimeException
{
    public function __construct(public readonly string $reason, public readonly mixed $detail = null)
    {
        parent::__construct($reason . ': ' . (is_scalar($detail) ? (string) $detail : get_debug_type($detail)));
    }
}

/**
 * Pure-PHP MessagePack codec implementing the exact subset used by the
 * Portals v1 wire protocol, including the Erlang-value extensions
 * (protocol/v1.md §5). Deliberately dependency-free — no `msgpack`
 * extension, GMP or BCMath — so a bare trusted-worker environment needs
 * nothing beyond PHP core, and so the ext-type semantics stay byte-for-byte
 * identical to `lib/portals/codec/message_pack.ex`.
 *
 * Host mapping: `null`/`bool`/`int`/`float` are native; a PHP `string`
 * encodes as `str`; `Bin` as `bin`; a list `array` as an array; a non-list
 * `array`, `Map` or `stdClass` as a map; `Tuple`/`Atom`/`Pid`/`Reference`/
 * `BigInt`/`ImproperList` as their extensions. Decoding returns the same
 * types (maps as `Map`, `bin` as `Bin`).
 */
final class MsgpackCodec
{
    public const EXT_TUPLE = 0;
    public const EXT_ATOM = 1;
    public const EXT_PID = 2;
    public const EXT_REFERENCE = 3;
    public const EXT_BIGINT = 4;
    public const EXT_IMPROPER_LIST = 5;

    /** Integers below this are sent as the bigint extension, matching Elixir. */
    public const INT_LOWER_BOUND = -1_099_511_627_776;

    private const EXT_FIXED_BY_SIZE = [1 => 0xD4, 2 => 0xD5, 4 => 0xD6, 8 => 0xD7, 16 => 0xD8];
    private const EXT_SIZE_BY_TAG = [0xD4 => 1, 0xD5 => 2, 0xD6 => 4, 0xD7 => 8, 0xD8 => 16];
    private const KNOWN_HEADERS = [
        0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8,
        0xD9, 0xDA, 0xDB, 0xDC, 0xDD, 0xDE, 0xDF,
    ];

    // -- Encoding -----------------------------------------------------------

    public static function encode(mixed $envelope, array $limits = Protocol::DEFAULT_LIMITS): string
    {
        $body = self::encodeTerm($envelope, 0, $limits);
        if (\strlen($body) > $limits['max_frame_size']) {
            throw new DecodeError('max_size_exceeded', \strlen($body));
        }
        return $body;
    }

    private static function encodeTerm(mixed $term, int $depth, array $limits): string
    {
        self::checkDepth($depth, $limits);

        if ($term === null) {
            return "\xC0";
        }
        if ($term === false) {
            return "\xC2";
        }
        if ($term === true) {
            return "\xC3";
        }
        if (\is_int($term)) {
            return self::encodeInt($term);
        }
        if (\is_float($term)) {
            return "\xCB" . pack('E', $term);
        }
        if (\is_string($term)) {
            return self::encodeStr($term);
        }
        if (\is_array($term)) {
            self::checkLength(\count($term), $limits);
            return array_is_list($term)
                ? self::encodeArray($term, $depth + 1, $limits)
                : self::encodeMap($term, $depth, $limits);
        }
        if ($term instanceof Bin) {
            return self::encodeBin($term->data);
        }
        if ($term instanceof Map) {
            self::checkLength(\count($term), $limits);
            return self::encodeMap($term->toArray(), $depth, $limits);
        }
        if ($term instanceof Atom) {
            return self::encodeExt(self::EXT_ATOM, $term->name);
        }
        if ($term instanceof Pid) {
            return self::encodeExt(self::EXT_PID, $term->raw);
        }
        if ($term instanceof Reference) {
            return self::encodeExt(self::EXT_REFERENCE, $term->raw);
        }
        if ($term instanceof Tuple) {
            self::checkLength(\count($term->items), $limits);
            return self::encodeExt(self::EXT_TUPLE, self::encodeArray($term->items, $depth + 1, $limits));
        }
        if ($term instanceof ImproperList) {
            return self::encodeExt(
                self::EXT_IMPROPER_LIST,
                self::encodeArray([$term->items, $term->tail], $depth + 1, $limits)
            );
        }
        if ($term instanceof BigInt) {
            if ($term->fitsInt()) {
                return self::encodeInt($term->toInt());
            }
            if ($term->fitsUint64()) {
                return "\xCF" . str_pad($term->magnitude, 8, "\0", STR_PAD_LEFT);
            }
            return self::encodeExt(self::EXT_BIGINT, ($term->negative ? "\x01" : "\x00") . $term->magnitude);
        }
        if ($term instanceof \BackedEnum) {
            return self::encodeTerm($term->value, $depth, $limits);
        }
        if ($term instanceof \UnitEnum) {
            return self::encodeExt(self::EXT_ATOM, $term->name);
        }
        if ($term instanceof \stdClass || $term instanceof \JsonSerializable) {
            $value = $term instanceof \JsonSerializable ? $term->jsonSerialize() : get_object_vars($term);
            if ($value instanceof \stdClass) {
                $value = get_object_vars($value);
            }
            if (\is_array($value)) {
                self::checkLength(\count($value), $limits);
                return self::encodeMap($value, $depth, $limits);
            }
            return self::encodeTerm($value, $depth, $limits);
        }

        throw new DecodeError('invalid_encoding', 'unsupported type ' . get_debug_type($term));
    }

    private static function encodeStr(string $bytes): string
    {
        $n = \strlen($bytes);
        if ($n < 32) {
            return \chr(0xA0 | $n) . $bytes;
        }
        if ($n < 256) {
            return "\xD9" . \chr($n) . $bytes;
        }
        if ($n < 65536) {
            return "\xDA" . pack('n', $n) . $bytes;
        }
        return "\xDB" . pack('N', $n) . $bytes;
    }

    private static function encodeBin(string $bytes): string
    {
        $n = \strlen($bytes);
        if ($n < 256) {
            return "\xC4" . \chr($n) . $bytes;
        }
        if ($n < 65536) {
            return "\xC5" . pack('n', $n) . $bytes;
        }
        return "\xC6" . pack('N', $n) . $bytes;
    }

    private static function encodeArray(array $items, int $depth, array $limits): string
    {
        $n = \count($items);
        $out = $n < 16 ? \chr(0x90 | $n) : ($n < 65536 ? "\xDC" . pack('n', $n) : "\xDD" . pack('N', $n));
        foreach ($items as $item) {
            $out .= self::encodeTerm($item, $depth, $limits);
        }
        return $out;
    }

    private static function encodeMap(array $entries, int $depth, array $limits): string
    {
        $n = \count($entries);
        $out = $n < 16 ? \chr(0x80 | $n) : ($n < 65536 ? "\xDE" . pack('n', $n) : "\xDF" . pack('N', $n));
        foreach ($entries as $key => $value) {
            $out .= self::encodeStr((string) $key);
            $out .= self::encodeTerm($value, $depth + 1, $limits);
        }
        return $out;
    }

    public static function encodeInt(int $n): string
    {
        if ($n < self::INT_LOWER_BOUND) {
            // -n cannot overflow except for PHP_INT_MIN, whose magnitude is 2^63.
            $magnitude = $n === PHP_INT_MIN ? "\x80" . str_repeat("\0", 7) : ltrim(pack('J', -$n), "\0");
            return self::encodeExt(self::EXT_BIGINT, "\x01" . $magnitude);
        }
        if ($n >= 0) {
            if ($n < 128) {
                return \chr($n);
            }
            if ($n < 256) {
                return "\xCC" . \chr($n);
            }
            if ($n < 65536) {
                return "\xCD" . pack('n', $n);
            }
            if ($n < 4294967296) {
                return "\xCE" . pack('N', $n);
            }
            return "\xCF" . pack('J', $n);
        }
        if ($n >= -32) {
            return \chr(0xE0 | ($n + 32));
        }
        if ($n >= -128) {
            return "\xD0" . pack('c', $n);
        }
        if ($n >= -32768) {
            return "\xD1" . pack('n', $n & 0xFFFF);
        }
        if ($n >= -2147483648) {
            return "\xD2" . pack('N', $n & 0xFFFFFFFF);
        }
        return "\xD3" . pack('J', $n);
    }

    private static function encodeExt(int $typeCode, string $payload): string
    {
        $n = \strlen($payload);
        $code = \chr($typeCode & 0xFF);
        if (isset(self::EXT_FIXED_BY_SIZE[$n])) {
            return \chr(self::EXT_FIXED_BY_SIZE[$n]) . $code . $payload;
        }
        if ($n < 256) {
            return "\xC7" . \chr($n) . $code . $payload;
        }
        if ($n < 65536) {
            return "\xC8" . pack('n', $n) . $code . $payload;
        }
        return "\xC9" . pack('N', $n) . $code . $payload;
    }

    // -- Decoding -----------------------------------------------------------

    /**
     * Decode one term from the front of `$data`. Returns `[term, rest]`,
     * where `rest` is any bytes left over. A non-array top-level term is
     * wrapped in a one-element list, as in the other SDKs.
     *
     * @return array{0: mixed, 1: string}
     */
    public static function decode(string $data, array $limits = Protocol::DEFAULT_LIMITS): array
    {
        if (\strlen($data) > $limits['max_frame_size']) {
            throw new DecodeError('max_size_exceeded', \strlen($data));
        }
        $pos = 0;
        $term = self::decodeTerm($data, $pos, 0, $limits);
        return [\is_array($term) ? $term : [$term], (string) substr($data, $pos)];
    }

    private static function need(string $data, int $pos, int $count): void
    {
        if (\strlen($data) - $pos < $count) {
            throw new DecodeError('truncated', max(\strlen($data) - $pos, 0));
        }
    }

    private static function decodeTerm(string $data, int &$pos, int $depth, array $limits): mixed
    {
        self::checkDepth($depth, $limits);
        self::need($data, $pos, 1);
        $b0 = \ord($data[$pos]);

        switch ($b0) {
            case 0xC0:
                $pos += 1;
                return null;
            case 0xC2:
                $pos += 1;
                return false;
            case 0xC3:
                $pos += 1;
                return true;
            case 0xCC:
                return self::fixed($data, $pos, 1, 'C');
            case 0xCD:
                return self::fixed($data, $pos, 2, 'n');
            case 0xCE:
                return self::fixed($data, $pos, 4, 'N');
            case 0xCF:
                self::need($data, $pos, 9);
                $raw = substr($data, $pos + 1, 8);
                $pos += 9;
                $value = unpack('J', $raw)[1];
                // Above PHP_INT_MAX the bit pattern reads as negative.
                return $value >= 0 ? $value : new BigInt(false, $raw);
            case 0xD0:
                return self::fixed($data, $pos, 1, 'c');
            case 0xD1:
                $value = self::fixed($data, $pos, 2, 'n');
                return $value >= 0x8000 ? $value - 0x10000 : $value;
            case 0xD2:
                $value = self::fixed($data, $pos, 4, 'N');
                return $value >= 0x80000000 ? $value - 0x100000000 : $value;
            case 0xD3:
                return self::fixed($data, $pos, 8, 'J');
            case 0xCA:
                return self::fixed($data, $pos, 4, 'G');
            case 0xCB:
                return self::fixed($data, $pos, 8, 'E');
            case 0xC4:
                return new Bin(self::sized($data, $pos, 1));
            case 0xC5:
                return new Bin(self::sized($data, $pos, 2));
            case 0xC6:
                return new Bin(self::sized($data, $pos, 4));
            case 0xD9:
                return self::sized($data, $pos, 1);
            case 0xDA:
                return self::sized($data, $pos, 2);
            case 0xDB:
                return self::sized($data, $pos, 4);
            case 0xDC:
                return self::decodeArray(self::fixed($data, $pos, 2, 'n'), $data, $pos, $depth, $limits);
            case 0xDD:
                return self::decodeArray(self::fixed($data, $pos, 4, 'N'), $data, $pos, $depth, $limits);
            case 0xDE:
                return self::decodeMap(self::fixed($data, $pos, 2, 'n'), $data, $pos, $depth, $limits);
            case 0xDF:
                return self::decodeMap(self::fixed($data, $pos, 4, 'N'), $data, $pos, $depth, $limits);
            case 0xC7:
                return self::decodeExtAt($data, $pos, self::lengthAt($data, $pos, 1), 2, $depth, $limits);
            case 0xC8:
                return self::decodeExtAt($data, $pos, self::lengthAt($data, $pos, 2), 3, $depth, $limits);
            case 0xC9:
                return self::decodeExtAt($data, $pos, self::lengthAt($data, $pos, 4), 5, $depth, $limits);
        }

        if ($b0 < 0x80) {
            $pos += 1;
            return $b0;
        }
        if ($b0 >= 0xE0) {
            $pos += 1;
            return $b0 - 256;
        }
        if ($b0 >= 0xA0 && $b0 <= 0xBF) {
            $n = $b0 & 0x1F;
            self::need($data, $pos + 1, $n);
            $value = (string) substr($data, $pos + 1, $n);
            $pos += 1 + $n;
            return $value;
        }
        if ($b0 >= 0x90 && $b0 <= 0x9F) {
            $pos += 1;
            return self::decodeArray($b0 & 0x0F, $data, $pos, $depth, $limits);
        }
        if ($b0 >= 0x80 && $b0 <= 0x8F) {
            $pos += 1;
            return self::decodeMap($b0 & 0x0F, $data, $pos, $depth, $limits);
        }
        if (isset(self::EXT_SIZE_BY_TAG[$b0])) {
            return self::decodeExtAt($data, $pos, self::EXT_SIZE_BY_TAG[$b0], 1, $depth, $limits);
        }
        if (\in_array($b0, self::KNOWN_HEADERS, true)) {
            throw new DecodeError('truncated', \strlen($data) - $pos);
        }
        throw new DecodeError('invalid_encoding', $b0);
    }

    /** Read a fixed-width value after the 1-byte header and advance past it. */
    private static function fixed(string $data, int &$pos, int $size, string $format): int|float
    {
        self::need($data, $pos, 1 + $size);
        $value = unpack($format, $data, $pos + 1)[1];
        $pos += 1 + $size;
        return $value;
    }

    /** Read the length field of a variable-size header without advancing. */
    private static function lengthAt(string $data, int $pos, int $headerSize): int
    {
        self::need($data, $pos, 1 + $headerSize);
        return unpack([1 => 'C', 2 => 'n', 4 => 'N'][$headerSize], $data, $pos + 1)[1];
    }

    /** Read a length-prefixed byte payload (str/bin) and advance past it. */
    private static function sized(string $data, int &$pos, int $headerSize): string
    {
        $n = self::lengthAt($data, $pos, $headerSize);
        $start = $pos + 1 + $headerSize;
        self::need($data, $start, $n);
        $pos = $start + $n;
        return (string) substr($data, $start, $n);
    }

    private static function decodeArray(int $count, string $data, int &$pos, int $depth, array $limits): array
    {
        self::checkLength($count, $limits);
        $items = [];
        for ($i = 0; $i < $count; $i++) {
            $items[] = self::decodeTerm($data, $pos, $depth + 1, $limits);
        }
        return $items;
    }

    private static function decodeMap(int $count, string $data, int &$pos, int $depth, array $limits): Map
    {
        self::checkLength($count, $limits);
        $map = new Map();
        for ($i = 0; $i < $count; $i++) {
            $key = self::decodeTerm($data, $pos, $depth + 1, $limits);
            $map[self::keyString($key)] = self::decodeTerm($data, $pos, $depth + 1, $limits);
        }
        return $map;
    }

    private static function keyString(mixed $key): string
    {
        if (\is_string($key) || \is_int($key) || $key instanceof \Stringable) {
            return (string) $key;
        }
        return var_export($key, true);
    }

    private static function decodeExtAt(
        string $data,
        int &$pos,
        int $payloadSize,
        int $headerSize,
        int $depth,
        array $limits
    ): mixed {
        $typePos = $pos + $headerSize;
        self::need($data, $typePos, 1 + $payloadSize);
        $typeCode = unpack('c', $data, $typePos)[1];
        $payload = (string) substr($data, $typePos + 1, $payloadSize);
        $pos = $typePos + 1 + $payloadSize;
        return self::decodeExt($typeCode, $payload, $depth, $limits);
    }

    private static function decodeExt(int $typeCode, string $payload, int $depth, array $limits): mixed
    {
        switch ($typeCode) {
            case self::EXT_BIGINT:
                $sign = $payload === '' ? -1 : \ord($payload[0]);
                if ($sign !== 0 && $sign !== 1) {
                    throw new DecodeError('invalid_extension', 'bigint');
                }
                return BigInt::of($sign === 1, (string) substr($payload, 1));
            case self::EXT_ATOM:
                // PHP has no BEAM atom table, so §5.3's unsafe-atom concern
                // does not apply; the text round-trips as an opaque Atom.
                if (!mb_check_encoding($payload, 'UTF-8')) {
                    throw new DecodeError('invalid_extension', 'atom');
                }
                return new Atom($payload);
            case self::EXT_PID:
                return new Pid($payload);
            case self::EXT_REFERENCE:
                return new Reference($payload);
            case self::EXT_TUPLE:
                $inner = 0;
                $items = self::decodeTerm($payload, $inner, $depth + 1, $limits);
                if (!\is_array($items) || $inner !== \strlen($payload)) {
                    throw new DecodeError('invalid_extension', 'tuple');
                }
                return new Tuple($items);
            case self::EXT_IMPROPER_LIST:
                $inner = 0;
                $pair = self::decodeTerm($payload, $inner, $depth + 1, $limits);
                if (!\is_array($pair) || \count($pair) !== 2 || $inner !== \strlen($payload) || !\is_array($pair[0])) {
                    throw new DecodeError('invalid_extension', 'improper_list');
                }
                return new ImproperList($pair[0], $pair[1]);
            default:
                throw new DecodeError('invalid_extension', $typeCode);
        }
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
