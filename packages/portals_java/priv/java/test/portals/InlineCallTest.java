package portals;

import static portals.TestSupport.assertEquals;
import static portals.TestSupport.assertTrue;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Map;

/** Inline calls (protocol/v1.md §7.1): run on the reader, no callbacks. */
public final class InlineCallTest {
  private InlineCallTest() {}

  /**
   * A worker wired to an in-memory connection and no call pool, so a CALL
   * that is not run inline fails loudly instead of running elsewhere.
   */
  private static Worker worker(ByteArrayOutputStream out, Handler handler) {
    Worker worker = new Worker().logger(message -> { }).function("m", "f", handler);
    worker.conn = FramedConnection.fromStreams(new ByteArrayInputStream(new byte[0]), out);
    return worker;
  }

  private static void call(Worker worker, Object... fields) throws Exception {
    List<Object> envelope = new ArrayList<>();
    envelope.add((long) Protocol.CALL);
    envelope.addAll(Arrays.asList(fields));
    worker.handleFrame(Codec.ETF.encode(envelope, Limits.DEFAULT));
  }

  private static List<Object> reply(ByteArrayOutputStream out) throws Exception {
    FramedConnection in = FramedConnection.fromStreams(new ByteArrayInputStream(out.toByteArray()), new ByteArrayOutputStream());
    return Codec.ETF.decodeEnvelope(in.recvFrame(), Limits.DEFAULT);
  }

  public static void testInlineCallRunsOnTheReaderThread() throws Exception {
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    Thread reader = Thread.currentThread();
    Worker worker = worker(out, args -> Thread.currentThread() == reader);

    call(worker, 7L, "m", "f", List.of(), null, 0L, true);

    assertEquals(List.of((long) Protocol.RETURN, 7L, true), reply(out));
    assertTrue(Worker.CONTEXT.get() == null, "the reader's call context is cleared");
  }

  public static void testCallbackFailsAtOnceInsideAnInlineCall() throws Exception {
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    Worker[] self = new Worker[1];
    self[0] = worker(out, args -> self[0].callCallback("m", "g", List.of(), -1));

    call(self[0], 8L, "m", "f", List.of(), null, 0L, true);

    List<Object> frame = reply(out);
    assertEquals((long) Protocol.ERROR, frame.get(0));
    assertEquals(8L, frame.get(1));
    String message = String.valueOf(((Map<?, ?>) frame.get(2)).get("message"));
    assertTrue(message.contains("inline"), "error mentions inline: " + message);
  }
}
