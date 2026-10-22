<?php

declare(strict_types=1);

namespace Portals\Tests;

use Portals\Atom;
use Portals\BigInt;
use Portals\Bin;
use Portals\DecodeError;
use Portals\EtfCodec;
use Portals\ImproperList;
use Portals\Map;
use Portals\Pid;
use Portals\Protocol;
use Portals\Reference;
use Portals\Tuple;

/**
 * Mirrors `packages/portals_python/priv/python/tests/test_etf_codec.py`, so
 * every ETF codec is held to the same contract (protocol/v1.md §5.4).
 */
final class EtfCodecTest extends TestCase
{
    /**
     * `:erlang.term_to_binary/1` of
     *   [3, 7, "héllo", %{"k" => [1, -2, 300, 2_147_483_648, -(2**70)]},
     *    {:ok, nil, true, false}, 1.5, [], ~c"ab", [1 | 2],
     *    %Portals.Codec.Bin{data: <<0, 255>>}]
     */
    private const BEAM_HEX = '836c0000000a610361076d0000000668c3a96c6c6f74000000016d000000016b6c00000005610162fffffffe'
        . '620000012c6e0400000000806e09010000000000000000406a68046400026f6b6400036e696c640004747275'
        . '6564000566616c7365463ff80000000000006a6b000261626c0000000161016102740000000264000a5f5f73'
        . '74727563745f5f640018456c697869722e506f7274616c732e436f6465632e42696e640004646174616d0000'
        . '000200ff6a';

    /** `self()` and `make_ref()` from a BEAM, as NEW_PID_EXT / NEWER_REFERENCE_EXT. */
    private const PID_HEX = '5864000d6e6f6e6f6465406e6f686f73740000005e0000000000000000';
    private const REF_HEX = '5a000364000d6e6f6e6f6465406e6f686f73740000000000008033634c0004263763cf';

    private function roundTrip(mixed $envelope, array $limits = Protocol::DEFAULT_LIMITS): mixed
    {
        [$decoded, $rest] = EtfCodec::decode(EtfCodec::encode($envelope, $limits), $limits);
        $this->assertSame('', $rest);
        return $decoded;
    }

    private function reason(string $bytes, array $limits = Protocol::DEFAULT_LIMITS): string
    {
        return $this->assertThrows(DecodeError::class, fn () => EtfCodec::decode($bytes, $limits))->reason;
    }

    private function encodeReason(mixed $term, array $limits): string
    {
        return $this->assertThrows(DecodeError::class, fn () => EtfCodec::encode($term, $limits))->reason;
    }

    public function testDecodesWhatTheBeamEncodes(): void
    {
        [$term, $rest] = EtfCodec::decode(hex2bin(self::BEAM_HEX));
        $this->assertSame('', $rest);
        $this->assertEquals([
            3,
            7,
            'héllo',
            new Map(['k' => [1, -2, 300, 2_147_483_648, BigInt::fromDecimal('-1180591620717411303424')]]),
            new Tuple([new Atom('ok'), null, true, false]),
            1.5,
            [],
            [97, 98],
            new ImproperList([1], 2),
            new Bin("\x00\xFF"),
        ], $term);
        $this->assertSame([3, 7, 'héllo'], \array_slice($term, 0, 3));
        $this->assertSame([null, true, false], \array_slice($term[4]->items, 1));
    }

    public function testRoundTripsEveryValueType(): void
    {
        $envelope = [
            4,
            1,
            new Map([
                'none' => null,
                'bools' => [true, false],
                'ints' => [0, 255, 256, -1, 2 ** 31, -(2 ** 31) - 1, PHP_INT_MAX, PHP_INT_MIN],
                'bigints' => [
                    BigInt::fromDecimal('18446744073709551616'),
                    BigInt::fromDecimal('-' . str_repeat('9', 700)),
                ],
                'float' => -0.25,
                'text' => 'naïve ✓',
                'bytes' => new Bin("\x00\x01\xFE"),
                'empty' => new Bin(''),
                'empty_map' => new Map(),
                'atom' => new Atom('ok'),
                'tuple' => new Tuple([1, 'two', new Tuple([3])]),
                'improper' => new ImproperList([1, 2], 'tail'),
                'nested' => new Map(['a' => [new Map(['b' => []])]]),
                'charlist' => [97, 98],
            ]),
        ];
        $decoded = $this->roundTrip($envelope);
        $this->assertEquals($envelope, $decoded);
        $this->assertSame([0, 255, 256, -1, 2 ** 31, -(2 ** 31) - 1, PHP_INT_MAX, PHP_INT_MIN], $decoded[2]['ints']);
        $this->assertSame('-' . str_repeat('9', 700), (string) $decoded[2]['bigints'][1]);
        $this->assertInstanceOf(Map::class, $decoded[2]['empty_map']);
    }

    public function testIntegerEncodings(): void
    {
        $this->assertSame("\x83\x61\xFF", EtfCodec::encode(255));
        $this->assertSame("\x83\x62\x00\x00\x01\x00", EtfCodec::encode(256));
        $this->assertSame("\x83\x62\xFF\xFF\xFF\xFF", EtfCodec::encode(-1));
        $this->assertSame("\x83\x6E\x04\x00\x00\x00\x00\x80", EtfCodec::encode(2 ** 31));
        $this->assertSame("\x83\x6E\x08\x01" . str_repeat("\0", 7) . "\x80", EtfCodec::encode(PHP_INT_MIN));
        // Past 255 digit bytes, LARGE_BIG_EXT.
        $huge = new BigInt(true, "\x10" . str_repeat("\0", 262));
        $this->assertSame("\x83\x6F\x00\x00\x01\x07\x01" . str_repeat("\0", 262) . "\x10", EtfCodec::encode($huge));
        $this->assertEquals([$huge], $this->roundTrip($huge));
    }

    public function testPhpArraysAndOtherValuesEncodeAsUnderMessagePack(): void
    {
        $this->assertSame("\x83\x6A", EtfCodec::encode([]));
        $this->assertSame("\x83\x74\x00\x00\x00\x00", EtfCodec::encode(new Map()));
        $this->assertSame("\x83\x77\x03nil", EtfCodec::encode(null));
        // A non-list array is a map with text keys, even numeric ones.
        $decoded = $this->roundTrip([[1 => 'x', 'k' => 'y']])[0];
        $this->assertInstanceOf(Map::class, $decoded);
        $this->assertEquals(new Map(['1' => 'x', 'k' => 'y']), $decoded);
        $this->assertEquals([new Map(['a' => 1])], $this->roundTrip((object) ['a' => 1]));
    }

    public function testPidsAndReferencesAreOpaqueAndWrittenBackVerbatim(): void
    {
        $pid = hex2bin(self::PID_HEX);
        $ref = hex2bin(self::REF_HEX);
        $data = "\x83\x6C\x00\x00\x00\x02" . $pid . $ref . "\x6A";
        [$term] = EtfCodec::decode($data);
        $this->assertEquals([new Pid($pid), new Reference($ref)], $term);
        $this->assertSame($data, EtfCodec::encode($term));
    }

    public function testADataKeyOutsideABinStructStaysText(): void
    {
        [$term] = EtfCodec::decode(
            "\x83\x6C\x00\x00\x00\x01\x74\x00\x00\x00\x02"
            . "\x77\x04data\x6D\x00\x00\x00\x01x"
            . "\x77\x05other\x61\x01"
            . "\x6A"
        );
        $this->assertSame(1, \count($term));
        $this->assertInstanceOf(Map::class, $term[0]);
        $this->assertSame(['data' => 'x', 'other' => 1], $term[0]->toArray());

        // Same for a binary-keyed "data" next to the struct key.
        [$term] = EtfCodec::decode(
            "\x83\x74\x00\x00\x00\x02\x77\x0A__struct__\x77\x18Elixir.Portals.Codec.Bin"
            . "\x6D\x00\x00\x00\x04data\x6D\x00\x00\x00\x01x"
        );
        $this->assertEquals([new Map(['__struct__' => new Atom('Elixir.Portals.Codec.Bin'), 'data' => 'x'])], $term);
    }

    public function testABinStructDecodesWithItsKeysInEitherOrder(): void
    {
        $bin = "\x83\x74\x00\x00\x00\x02\x77\x04data\x6D\x00\x00\x00\x02\x00\xFF"
            . "\x77\x0A__struct__\x77\x18Elixir.Portals.Codec.Bin";
        $this->assertEquals([new Bin("\x00\xFF")], EtfCodec::decode($bin)[0]);
        $this->assertSame(
            "\x83\x74\x00\x00\x00\x02\x77\x0A__struct__\x77\x18Elixir.Portals.Codec.Bin"
            . "\x77\x04data\x6D\x00\x00\x00\x02\x00\xFF",
            EtfCodec::encode(new Bin("\x00\xFF"))
        );
    }

    public function testMapKeysBecomeTextAsUnderMessagePack(): void
    {
        // %{a: 1, 2 => 3, "s" => 4, nil => 5} from a BEAM.
        [$term] = EtfCodec::decode(hex2bin('837400000004610261036400016161016400036e696c61056d00000001736104'));
        $this->assertInstanceOf(Map::class, $term[0]);
        $keys = [];
        foreach ($term[0] as $key => $value) {
            $keys[$key] = $value;
        }
        ksort($keys, SORT_STRING);
        $this->assertSame(['' => 5, '2' => 3, 'a' => 1, 's' => 4], $keys);
        $this->assertSame(['1' => 'x', 'k' => 'y'], iterator_to_array($this->roundTrip([new Map(['1' => 'x', 'k' => 'y'])])[0]));

        // Any other key type has no text form.
        $this->assertSame('invalid_encoding', $this->reason("\x83\x74\x00\x00\x00\x01\x68\x00\x61\x01"));
    }

    public function testMalformedInputIsRejectedWithItsReason(): void
    {
        $beam = hex2bin(self::BEAM_HEX);
        $this->assertSame('truncated', $this->reason(''));
        $this->assertSame('invalid_encoding', $this->reason("\x00"));
        $this->assertSame('truncated', $this->reason(substr($beam, 0, -3)));
        $this->assertSame('truncated', $this->reason("\x83\x6C\x00\x00\x00\x03\x61\x01"));
        $this->assertSame('truncated', $this->reason("\x83\x6D\x00\x00\x00\x0Ashort"));
        $this->assertSame('invalid_encoding', $this->reason("\x83\x4D"));
        $this->assertSame('invalid_encoding', $this->reason("\x83\x4D\x00\x00\x00\x01\x03\xE0"));
        $this->assertSame('invalid_encoding', $this->reason("\x83\xC8"));
        // Compressed terms and old float encodings are not part of the codec.
        $this->assertSame('invalid_encoding', $this->reason("\x83\x50\x00\x00\x00\x01\x78"));
        $this->assertSame('invalid_encoding', $this->reason("\x83\x63" . str_repeat('0', 31)));
        $this->assertSame('invalid_encoding', $this->reason("\x83\x6D\x00\x00\x00\x01\xFF"));
        $this->assertSame('invalid_encoding', $this->reason("\x83\x77\x01\xFF"));
        $this->assertSame('max_length_exceeded', $this->reason("\x83\x6C\xFF\xFF\xFF\xFF"));
        $this->assertSame('max_length_exceeded', $this->reason("\x83\x74\xFF\xFF\xFF\xFF"));

        // Unknown atoms are fine (PHP has no atom table) and trailing bytes are the frame reader's call.
        $this->assertEquals([[new Atom('not_a_real_atom_xyzq')], ''], EtfCodec::decode("\x83\x77\x14not_a_real_atom_xyzq"));
        $this->assertSame([[1], "\x00"], EtfCodec::decode("\x83\x61\x01\x00"));
    }

    public function testLatin1AtomsDecodeAsUtf8(): void
    {
        $this->assertEquals([new Atom('é')], EtfCodec::decode("\x83\x73\x01\xE9")[0]);
        $this->assertEquals([new Atom('é')], EtfCodec::decode("\x83\x64\x00\x01\xE9")[0]);
        $this->assertSame([true], EtfCodec::decode("\x83\x64\x00\x04true")[0]);
    }

    public function testDecodeEnforcesLimits(): void
    {
        $nested = "\x83" . str_repeat("\x6C\x00\x00\x00\x01", 40) . "\x61\x01" . str_repeat("\x6A", 40);
        $this->assertSame('max_depth_exceeded', $this->reason($nested));

        $tight = ['max_frame_size' => 1024, 'max_nesting_depth' => 2, 'max_collection_length' => 3];
        $this->assertSame('max_depth_exceeded', $this->reason(EtfCodec::encode([[[[1]]]]), $tight));
        $this->assertSame('max_length_exceeded', $this->reason(EtfCodec::encode([[1, 2, 3, 4]]), $tight));
        $this->assertSame('max_length_exceeded', $this->reason(EtfCodec::encode(new Tuple([1, 2, 3, 4])), $tight));
        $this->assertSame('max_size_exceeded', $this->reason(EtfCodec::encode([str_repeat('x', 2000)]), $tight));
    }

    public function testEncodeEnforcesLimits(): void
    {
        $tight = ['max_frame_size' => 1024, 'max_nesting_depth' => 2, 'max_collection_length' => 3];
        $this->assertSame('max_depth_exceeded', $this->encodeReason([[[[1]]]], $tight));
        $this->assertSame('max_length_exceeded', $this->encodeReason([[1, 2, 3, 4]], $tight));
        $this->assertSame('max_length_exceeded', $this->encodeReason([new Map(['a' => 1, 'b' => 2, 'c' => 3, 'd' => 4])], $tight));
        $this->assertSame('max_size_exceeded', $this->encodeReason([str_repeat('x', 2000)], $tight));
        $this->assertSame('invalid_encoding', $this->encodeReason([fopen('php://memory', 'r')], Protocol::DEFAULT_LIMITS));
    }

    public function testLargeBinaryRoundTrips(): void
    {
        $blob = new Bin(str_repeat("\0", 70_000));
        $decoded = $this->roundTrip([Protocol::RETURN, 1, $blob]);
        $this->assertEquals($blob, $decoded[2]);
    }
}
