package com.example;

import java.util.List;
import portals.Pid;
import portals.Portals;
import portals.Stream;
import portals.StreamHandler;

public final class TextTools {
  private TextTools() {}

  // The wire name "word_count" maps onto wordCount.
  public static long wordCount(String text) {
    String trimmed = text.strip();
    return trimmed.isEmpty() ? 0 : trimmed.split("\\s+").length;
  }

  public static long parseInt(String text) {
    return Long.parseLong(text); // a NumberFormatException becomes %Portals.Error{kind: :remote}
  }

  public static long progress(long steps) throws InterruptedException {
    for (long step = 1; step <= steps; step++) {
      // Blocks this handler's thread until MyApp.Progress.report/1 returns.
      Portals.callback("Elixir.MyApp.Progress", "report", List.of(step));
    }
    return steps;
  }

  public static String notify(Pid pid, String text) {
    Portals.sendMessage(pid, text.toUpperCase()); // fire-and-forget
    return "sent";
  }

  @StreamHandler
  public static long upcaseStream(Stream stream) throws InterruptedException {
    long count = 0;
    for (Object chunk : stream) { // ends when the BEAM half-closes its side
      stream.send(((String) chunk).toUpperCase()); // blocks while the BEAM's credit is used up
      count++;
    }
    return count; // the stream's final result
  }
}
