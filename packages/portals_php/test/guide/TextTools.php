<?php

declare(strict_types=1);

use Portals\Pid;
use Portals\Stream;
use Portals\StreamHandler;

final class TextTools
{
    public static function word_count(string $text): int
    {
        return count(preg_split('/\s+/', trim($text), -1, PREG_SPLIT_NO_EMPTY));
    }

    public static function parse_int(string $text): int
    {
        if (filter_var($text, FILTER_VALIDATE_INT) === false) {
            // Becomes %Portals.Error{kind: :remote}.
            throw new InvalidArgumentException("not an integer: {$text}");
        }
        return (int) $text;
    }

    public static function progress(int $steps): int
    {
        for ($step = 1; $step <= $steps; $step++) {
            // Suspends only this call's fiber until MyApp.Progress.report/1 returns.
            Portals\callback('Elixir.MyApp.Progress', 'report', [$step]);
        }
        return $steps;
    }

    public static function notify(Pid $pid, string $text): string
    {
        Portals\send_message($pid, strtoupper($text)); // fire-and-forget
        return 'sent';
    }

    #[StreamHandler]
    public static function upcase_stream(Stream $stream): int
    {
        $count = 0;
        foreach ($stream as $chunk) {          // ends when the BEAM half-closes its side
            $stream->send(strtoupper($chunk)); // waits while the BEAM's credit is used up
            $count++;
        }
        return $count;                         // the stream's final result
    }
}
