<?php

declare(strict_types=1);

namespace Portals\Tests;

use Portals\Atom;
use Portals\BigInt;
use Portals\Bin;
use Portals\DecodeError;
use Portals\ImproperList;
use Portals\Map;
use Portals\MsgpackCodec;
use Portals\Pid;
use Portals\Protocol;
use Portals\Reference;
use Portals\Tuple;

/**
 * Mirrors `sdk/python/tests/test_msgpack_codec.py`,
 * `sdk/ruby/test/test_msgpack_codec.rb` and `sdk/node/test/msgpackCodec.test.js`
 * so every codec is held to the same contract.
 */
final class MsgpackCodecTest extends TestCase
{
    private function roundTrip(mixed $envelope): mixed
    {
        $encoded = MsgpackCodec::encode($envelope, Protocol::DEFAULT_LIMITS);
        [$decoded, $rest] = MsgpackCodec::decode($encoded, Protocol::DEFAULT_LIMITS);
        $this->assertSame('', $rest);
        return $decoded;
    }

    private function reason(string $bytes, array $limits = Protocol::DEFAULT_LIMITS): string
    {
        return $this->assertThrows(DecodeError::class, fn () => MsgpackCodec::decode($bytes, $limits))->reason;
    }

    public function testPrimitives(): void
    {
        $this->assertSame([null, true, false], $this->roundTrip([null, true, false]));
    }

    public function testIntsIncludingBigints(): void
    {
        $values = [0, 1, 127, 128, 255, 256, 65535, 65536, -1, -32, -33, -128, -129, -32768, -32769,
            4294967296, -2147483649, PHP_INT_MAX, PHP_INT_MIN, -1_099_511_627_777];
        $this->assertSame($values, $this->roundTrip($values));

        $huge = BigInt::fromDecimal('170141183460469231731687303715884105728');
        $negative = BigInt::fromDecimal('-170141183460469231731687303715884105728');
        $this->assertEquals([$huge, $negative], $this->roundTrip([$huge, $negative]));
        $this->assertSame('-170141183460469231731687303715884105728', (string) $negative);
    }

    public function testUint64AbovePhpIntMaxRoundTripsAsUint64(): void
    {
        $max = BigInt::fromDecimal('18446744073709551615');
        $this->assertSame("\xCF" . str_repeat("\xFF", 8), MsgpackCodec::encode($max));
        $decoded = $this->roundTrip([$max])[0];
        $this->assertInstanceOf(BigInt::class, $decoded);
        $this->assertSame('18446744073709551615', (string) $decoded);
    }

    public function testBigintsThatFitAreNormalisedToInt(): void
    {
        $this->assertSame(42, BigInt::fromDecimal('42'));
        $this->assertSame(PHP_INT_MIN, BigInt::fromDecimal((string) PHP_INT_MIN));
        // A bigint extension carrying a small value decodes to a plain int.
        $this->assertSame([5], MsgpackCodec::decode("\xD5\x04\x00\x05")[0]);
    }

    public function testIntegersUseTheSmallestEncoding(): void
    {
        $this->assertSame("\x7F", MsgpackCodec::encode(127));
        $this->assertSame("\xE0", MsgpackCodec::encode(-32));
        $this->assertSame("\xD0\xDF", MsgpackCodec::encode(-33));
        $this->assertSame("\xCD\x01\x00", MsgpackCodec::encode(256));
        $this->assertSame("\xD3" . pack('J', -1_099_511_627_776), MsgpackCodec::encode(-1_099_511_627_776));
        // Below -2^40 the Elixir codec switches to the bigint extension.
        $this->assertSame(
            "\xC7\x07\x04\x01\x01\x00\x00\x00\x00\x01",
            MsgpackCodec::encode(-1_099_511_627_777)
        );
    }

    public function testFloat(): void
    {
        $this->assertSame([1.5, 2.0], $this->roundTrip([1.5, 2.0]));
    }

    public function testStrAndBinAreDistinct(): void
    {
        $decoded = $this->roundTrip(['hello', new Bin("\x00\x01\x02")]);
        $this->assertSame('hello', $decoded[0]);
        $this->assertInstanceOf(Bin::class, $decoded[1]);
        $this->assertSame("\x00\x01\x02", $decoded[1]->data);
    }

    public function testTuple(): void
    {
        $this->assertEquals([new Tuple([1, 'a', null])], $this->roundTrip([new Tuple([1, 'a', null])]));
    }

    public function testAtomRoundTripsAsAnAtom(): void
    {
        $this->assertEquals([new Atom('ok')], $this->roundTrip([new Atom('ok')]));
    }

    public function testPidAndReferenceAreOpaqueRoundTrips(): void
    {
        $pid = new Pid("\x83pid_bytes");
        $ref = new Reference("\x83ref_bytes");
        $this->assertEquals([$pid, $ref], $this->roundTrip([$pid, $ref]));
    }

    public function testImproperList(): void
    {
        $value = new ImproperList([1, 2], new Atom('tail'));
        $this->assertEquals([$value], $this->roundTrip([$value]));
    }

    public function testNestedMap(): void
    {
        $term = ['a' => 1, 'b' => [1, 2, 3], 'c' => ['nested' => true]];
        $decoded = $this->roundTrip([$term])[0];
        $this->assertInstanceOf(Map::class, $decoded);
        $this->assertSame(1, $decoded['a']);
        $this->assertSame([1, 2, 3], $decoded['b']);
        $this->assertSame(true, $decoded['c']['nested']);
    }

    public function testEmptyAndNumericKeyedMapsStayMaps(): void
    {
        $this->assertSame("\x91\x80", MsgpackCodec::encode([new Map()]));
        $this->assertSame("\x91\x90", MsgpackCodec::encode([[]]));

        $numeric = new Map(['0' => 'a', '1' => 'b']);
        $decoded = $this->roundTrip([$numeric])[0];
        $this->assertInstanceOf(Map::class, $decoded);
        $this->assertSame(MsgpackCodec::encode([$numeric]), MsgpackCodec::encode([$decoded]));
        $keys = [];
        foreach ($decoded as $key => $_) {
            $keys[] = $key;
        }
        $this->assertSame(['0', '1'], $keys);
    }

    public function testCallAndHelloEnvelopeShapes(): void
    {
        $hello = [Protocol::HELLO, 1, 'php8.3', 16, 0, []];
        $this->assertSame($hello, $this->roundTrip($hello));

        $call = [Protocol::CALL, 1, 'bench_worker', 'echo', ['hello']];
        $this->assertSame($call, $this->roundTrip($call));
    }

    public function testMaxFrameSizeEnforced(): void
    {
        $tight = ['max_frame_size' => 4] + Protocol::DEFAULT_LIMITS;
        $this->assertThrows(DecodeError::class, fn () => MsgpackCodec::encode(['much too long a string'], $tight));
    }

    public function testMaxNestingDepthEnforced(): void
    {
        $tight = ['max_nesting_depth' => 2] + Protocol::DEFAULT_LIMITS;
        $this->assertSame('max_depth_exceeded', $this->reason("\x91\x91\x91\x91\x01", $tight));
    }

    public function testTruncatedFrameIsATruncatedDecodeError(): void
    {
        $this->assertSame('truncated', $this->reason("\x91"));
        $this->assertSame('truncated', $this->reason(''));
        $this->assertSame('truncated', $this->reason("\xD9"));
    }

    public function testUnknownLeadingByteIsInvalidEncoding(): void
    {
        $this->assertSame('invalid_encoding', $this->reason("\xC1"));
    }

    public function testOversizedCollectionIsRejected(): void
    {
        $this->assertSame('max_length_exceeded', $this->reason("\xDD\xFF\xFF\xFF\xFF"));
    }

    public function testInvalidExtensionsAreRejected(): void
    {
        $this->assertSame('invalid_extension', $this->reason("\xD4\x63\x00"));
        $this->assertSame('invalid_extension', $this->reason("\xC7\x02\x00\x90\x01"));
    }

    public function testLargeBinaryRoundTrips(): void
    {
        $blob = new Bin(str_repeat("\0", 70_000));
        $decoded = $this->roundTrip([Protocol::RETURN, 1, $blob]);
        $this->assertEquals($blob, $decoded[2]);
    }

    public function testReturnEnvelopeRoundTrip(): void
    {
        $decoded = $this->roundTrip([Protocol::RETURN, 42, ['ok' => true]]);
        $this->assertSame(42, $decoded[1]);
        $this->assertSame(['ok' => true], $decoded[2]->toArray());
    }
}
