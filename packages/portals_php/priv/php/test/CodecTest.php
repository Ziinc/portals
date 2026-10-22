<?php

declare(strict_types=1);

namespace Portals\Tests;

use Portals\Codec;
use Portals\EtfCodec;
use Portals\MsgpackCodec;

/** `PORTALS_CODEC` selection (protocol/v1.md §5.4). */
final class CodecTest extends TestCase
{
    public function testEtfIsTheDefaultAndMsgpackIsSelectable(): void
    {
        $selected = Codec::name();
        try {
            Codec::select(false);
            $this->assertSame('etf', Codec::name());
            $this->assertSame(EtfCodec::encode([1, 'x']), Codec::encode([1, 'x']));
            $this->assertSame([[1, 'x'], ''], Codec::decode(EtfCodec::encode([1, 'x'])));

            Codec::select('msgpack');
            $this->assertSame('msgpack', Codec::name());
            $this->assertSame(MsgpackCodec::encode([1, 'x']), Codec::encode([1, 'x']));
            $this->assertSame([[1, 'x'], ''], Codec::decode(MsgpackCodec::encode([1, 'x'])));
        } finally {
            Codec::select($selected);
        }
    }

    public function testAnUnknownCodecFailsFast(): void
    {
        $error = $this->assertThrows(\RuntimeException::class, fn () => Codec::select('json'));
        $this->assertSame("PORTALS_CODEC='json' is not a codec this SDK speaks (etf, msgpack)", $error->getMessage());
        $this->assertThrows(\RuntimeException::class, fn () => Codec::select(''));
    }

    public function testTheSdkStopsAtStartupOnAnUnknownCodec(): void
    {
        $cmd = 'PORTALS_CODEC=json ' . escapeshellarg(PHP_BINARY) . ' -r '
            . escapeshellarg('require ' . var_export(\dirname(__DIR__) . '/src/portals.php', true) . '; echo "started";')
            . ' 2>&1';
        exec($cmd, $output, $status);
        $this->assertTrue($status !== 0, 'expected a non-zero exit status');
        $this->assertTrue(str_contains(implode("\n", $output), "PORTALS_CODEC='json'"), implode("\n", $output));
        $this->assertFalse(str_contains(implode("\n", $output), 'started'));
    }
}
