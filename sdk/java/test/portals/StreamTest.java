package portals;

import static portals.TestSupport.assertEquals;
import static portals.TestSupport.assertThrows;
import static portals.TestSupport.assertTrue;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;

/**
 * Mirrors {@code sdk/ruby/test/test_streams.rb} and
 * {@code sdk/node/test/streams.test.js}: the credit window, the independent
 * queued-frame cap, per-direction half-close, and cancellation.
 */
public final class StreamTest {
  private StreamTest() {}

  static final long WINDOW = 1024;
  static final long MAX_FRAMES = 4;

  static final class Harness {
    final List<byte[]> sent = Collections.synchronizedList(new ArrayList<>());
    final Stream stream = new Stream(7L, WINDOW, MAX_FRAMES, sent::add,
        envelope -> MsgpackCodec.encode(envelope, Limits.DEFAULT));

    List<Object> frames() throws DecodeException {
      List<Object> frames = new ArrayList<>();
      synchronized (sent) {
        for (byte[] bytes : sent) frames.add(MsgpackCodec.decode(bytes).term());
      }
      return frames;
    }
  }

  static CompletableFuture<Void> async(TestSupport.Body body) {
    return CompletableFuture.runAsync(() -> {
      try {
        body.run();
      } catch (RuntimeException e) {
        throw e;
      } catch (Exception e) {
        throw new RuntimeException(e);
      }
    });
  }

  static Throwable failure(CompletableFuture<?> future) throws Exception {
    try {
      future.get(2, TimeUnit.SECONDS);
    } catch (ExecutionException e) {
      return e.getCause();
    }
    throw new AssertionError("expected the operation to fail");
  }

  public static void testInitialGrantOffersTheWholeWindowOnce() {
    Harness h = new Harness();
    assertEquals(WINDOW, h.stream.initialGrant());
    assertEquals(0L, h.stream.initialGrant());
  }

  public static void testInboundBeyondTheGrantedWindowIsRejected() {
    Harness h = new Harness();
    h.stream.initialGrant();
    h.stream.recordInbound("a", 512);
    assertThrows(StreamProtocolException.class, () -> h.stream.recordInbound("b", 600));
  }

  public static void testATinyFrameFloodHitsTheFrameLimitWhileBytesRemain() {
    Harness h = new Harness();
    h.stream.initialGrant();
    for (int i = 0; i < MAX_FRAMES; i++) h.stream.recordInbound(String.valueOf(i), 8);
    assertThrows(StreamProtocolException.class, () -> h.stream.recordInbound("one too many", 8));
  }

  public static void testConsumingReplenishesExactlyWhatWasConsumed() throws Exception {
    Harness h = new Harness();
    h.stream.initialGrant();
    h.stream.recordInbound("chunk", 100);

    assertEquals("chunk", h.stream.recv());
    List<Object> frames = h.frames();
    assertEquals(List.of((long) Protocol.CREDIT, 7L, 100L, 1L), frames.get(frames.size() - 1));
  }

  public static void testRecvReturnsNullAfterThePeerHalfCloses() throws Exception {
    Harness h = new Harness();
    h.stream.peerHalfClosed();
    assertEquals(null, h.stream.recv());
  }

  public static void testRecvTimesOut() {
    Harness h = new Harness();
    assertThrows(StreamTimeoutException.class, () -> h.stream.recv(20));
  }

  public static void testInboundAfterHalfCloseIsAProtocolError() {
    Harness h = new Harness();
    h.stream.initialGrant();
    h.stream.peerHalfClosed();
    assertThrows(StreamProtocolException.class, () -> h.stream.recordInbound("late", 8));
  }

  public static void testSendWaitsUntilCreditArrives() throws Exception {
    Harness h = new Harness();
    CompletableFuture<Void> pending = async(() -> h.stream.send("payload"));
    Thread.sleep(50);
    assertEquals(0, h.sent.size());

    h.stream.addSendCredit(WINDOW, 0);
    pending.get(2, TimeUnit.SECONDS);

    assertEquals(1, h.sent.size());
    assertEquals(List.of((long) Protocol.STREAM_DATA, 7L, "payload"), h.frames().get(0));
  }

  public static void testSendIsChargedTheFullFrameSizeIncludingThePrefix() throws Exception {
    Harness h = new Harness();
    byte[] payload = MsgpackCodec.encode(List.of(Protocol.STREAM_DATA, 7L, "payload"));
    h.stream.addSendCredit(payload.length + Stream.FRAME_PREFIX_BYTES, 0);
    h.stream.send("payload");
    assertEquals(1, h.sent.size());

    // Exactly one frame's worth of credit was granted, so the next send parks.
    CompletableFuture<Void> parked = async(() -> h.stream.send("payload"));
    Thread.sleep(50);
    assertEquals(1, h.sent.size());
    h.stream.cancel();
    assertTrue(failure(parked) instanceof StreamClosedException, "a cancelled sender gets StreamClosed");
  }

  public static void testSendRespectsTheUnacknowledgedFrameLimit() throws Exception {
    Harness h = new Harness();
    h.stream.addSendCredit(WINDOW, 0);
    for (int i = 0; i < MAX_FRAMES; i++) h.stream.send("x");
    assertEquals((int) MAX_FRAMES, h.sent.size());

    CompletableFuture<Void> parked = async(() -> h.stream.send("x"));
    Thread.sleep(50);
    assertEquals((int) MAX_FRAMES, h.sent.size());

    h.stream.addSendCredit(0, MAX_FRAMES);
    parked.get(2, TimeUnit.SECONDS);
    assertEquals((int) MAX_FRAMES + 1, h.sent.size());
  }

  public static void testAChunkLargerThanTheWindowCanNeverBeSent() {
    Harness h = new Harness();
    h.stream.addSendCredit(WINDOW, 0);
    assertThrows(StreamProtocolException.class, () -> h.stream.send("x".repeat((int) WINDOW * 2)));
  }

  public static void testHalfCloseIsPerDirectionAndIdempotent() throws Exception {
    Harness h = new Harness();
    h.stream.initialGrant();
    h.stream.halfClose();
    h.stream.halfClose();

    long halfCloses = h.frames().stream()
        .filter(frame -> ((List<?>) frame).get(0).equals((long) Protocol.HALF_CLOSE))
        .count();
    assertEquals(1L, halfCloses);
    assertThrows(StreamClosedException.class, () -> h.stream.send("late"));

    // The receiving direction is untouched.
    h.stream.recordInbound("still-arriving", 32);
    assertEquals("still-arriving", h.stream.recv());
  }

  public static void testCancelReleasesStateAndUnblocksAParkedSender() throws Exception {
    Harness h = new Harness();
    h.stream.initialGrant();
    h.stream.recordInbound("queued", 32);

    CompletableFuture<Void> parked = async(() -> h.stream.send("parked"));
    Thread.sleep(50);
    h.stream.cancel();

    assertTrue(failure(parked) instanceof StreamClosedException, "a cancelled sender gets StreamClosed");
    assertTrue(h.stream.isCancelled(), "stream reports cancelled");
    assertEquals(null, h.stream.recv());
  }

  public static void testIterationEndsAtHalfClose() {
    Harness h = new Harness();
    h.stream.initialGrant();
    h.stream.recordInbound("a", 16);
    h.stream.recordInbound("b", 16);
    h.stream.peerHalfClosed();
    List<Object> seen = new ArrayList<>();
    for (Object chunk : h.stream) seen.add(chunk);
    assertEquals(List.of("a", "b"), seen);
  }
}
