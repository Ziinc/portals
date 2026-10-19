package portals;

import java.util.ArrayDeque;
import java.util.Arrays;
import java.util.Iterator;
import java.util.List;
import java.util.NoSuchElementException;

/**
 * One open bidirectional stream (protocol/v1.md §9). Thread-safe.
 *
 * <p>A stream is opened by the BEAM as an ordinary {@code CALL} whose target
 * method is annotated {@link StreamHandler}; the call's {@code request_id}
 * doubles as the {@code stream_id}. The handler receives a {@code Stream} as
 * its first argument and runs on a dedicated stream thread pool, kept
 * separate from the unary pool so long-lived streams can never exhaust the
 * concurrency this worker advertised for unary calls.
 *
 * <p>Backpressure is an encoded-byte credit window, independent per
 * direction, charged against the complete encoded frame size (4-byte length
 * prefix included), plus a hard cap on queued-but-unconsumed frames so a
 * flood of tiny frames cannot evade the byte window.
 */
public final class Stream implements Iterable<Object> {
  public static final int FRAME_PREFIX_BYTES = 4;

  /** Sends one already-encoded envelope. */
  @FunctionalInterface
  public interface FrameSender {
    void send(byte[] payload) throws Exception;
  }

  /** Encodes one envelope. */
  @FunctionalInterface
  public interface Encoder {
    byte[] encode(List<Object> envelope) throws DecodeException;
  }

  private record Inbound(Object chunk, long frameSize) {}

  private final Object id;
  private final long maxCredit;
  private final long maxFrames;
  private final FrameSender sendFrame;
  private final Encoder encoder;

  private long sendCredit;
  private long sendFrames;
  private long recvCredit;
  private long recvBytes;
  private final ArrayDeque<Inbound> inbox = new ArrayDeque<>();
  private boolean outboundOpen = true;
  private boolean inboundOpen = true;
  private boolean cancelled;

  public Stream(Object streamId, long maxCredit, long maxFrames, FrameSender sendFrame, Encoder encoder) {
    this.id = streamId;
    this.maxCredit = maxCredit;
    this.maxFrames = maxFrames;
    this.sendFrame = sendFrame;
    this.encoder = encoder;
  }

  public Object id() {
    return id;
  }

  public synchronized boolean isCancelled() {
    return cancelled;
  }

  // -- receive side ---------------------------------------------------------

  /**
   * Bytes to grant the BEAM up front; also the replenishment amount after
   * consumption. Returns 0 when nothing is owed.
   */
  public synchronized long initialGrant() {
    return grantLocked();
  }

  /**
   * Accounts for one inbound {@code STREAM_DATA} frame.
   *
   * @throws StreamProtocolException when the peer exceeded its allowance
   */
  public synchronized void recordInbound(Object chunk, long frameSize) throws StreamProtocolException {
    if (!inboundOpen) throw new StreamProtocolException("STREAM_DATA after HALF_CLOSE");
    if (inbox.size() >= maxFrames) throw new StreamProtocolException("queued stream frame limit exceeded");
    if (frameSize > recvCredit) throw new StreamProtocolException("stream byte credit exceeded");

    recvCredit -= frameSize;
    recvBytes += frameSize;
    inbox.addLast(new Inbound(chunk, frameSize));
    notifyAll();
  }

  /**
   * The next inbound chunk, blocking without a timeout. Returns {@code null}
   * once the BEAM has half-closed its sending direction (or the stream was
   * cancelled). Consuming a chunk is what replenishes the BEAM's credit.
   */
  public Object recv() throws InterruptedException {
    try {
      return recv(-1);
    } catch (StreamTimeoutException e) {
      throw new IllegalStateException(e);
    }
  }

  /** Like {@link #recv()}, giving up after {@code timeoutMs} (negative: never). */
  public Object recv(long timeoutMs) throws InterruptedException, StreamTimeoutException {
    Inbound next;
    long grant;
    synchronized (this) {
      long deadline = deadlineFor(timeoutMs);
      while (inbox.isEmpty()) {
        if (cancelled || !inboundOpen) return null;
        waitUntil(deadline, "stream " + id + " receive timed out");
      }
      next = inbox.removeFirst();
      recvBytes -= next.frameSize();
      grant = grantLocked();
    }
    if (grant > 0) emit(Arrays.asList(Protocol.CREDIT, id, grant, 1));
    return next.chunk();
  }

  /** Iterates inbound chunks until the BEAM half-closes. */
  @Override
  public Iterator<Object> iterator() {
    return new Iterator<>() {
      private Object pending;
      private boolean done;

      @Override
      public boolean hasNext() {
        if (pending != null) return true;
        if (done) return false;
        try {
          pending = recv();
        } catch (InterruptedException e) {
          Thread.currentThread().interrupt();
          pending = null;
        }
        if (pending == null) done = true;
        return pending != null;
      }

      @Override
      public Object next() {
        if (!hasNext()) throw new NoSuchElementException();
        Object chunk = pending;
        pending = null;
        return chunk;
      }
    };
  }

  // -- send side ------------------------------------------------------------

  /**
   * Sends one chunk, blocking this handler's own thread (never the socket
   * reader) until the BEAM has granted enough credit.
   */
  public void send(Object chunk) throws InterruptedException, StreamClosedException, StreamProtocolException {
    try {
      send(chunk, -1);
    } catch (StreamTimeoutException e) {
      throw new IllegalStateException(e);
    }
  }

  /** Like {@link #send(Object)}, giving up after {@code timeoutMs} (negative: never). */
  public void send(Object chunk, long timeoutMs)
      throws InterruptedException, StreamClosedException, StreamProtocolException, StreamTimeoutException {
    byte[] payload;
    try {
      payload = encoder.encode(Arrays.asList(Protocol.STREAM_DATA, id, chunk));
    } catch (DecodeException e) {
      throw new StreamProtocolException("chunk cannot be encoded: " + e.getMessage());
    }
    long frameSize = payload.length + FRAME_PREFIX_BYTES;
    if (frameSize > maxCredit) {
      throw new StreamProtocolException(
          "chunk of " + frameSize + " bytes exceeds the stream window of " + maxCredit);
    }

    synchronized (this) {
      long deadline = deadlineFor(timeoutMs);
      while (true) {
        if (cancelled) throw new StreamClosedException("stream " + id + " was cancelled");
        if (!outboundOpen) throw new StreamClosedException("stream " + id + " outbound direction is half-closed");
        if (sendFrames < maxFrames && frameSize <= sendCredit) {
          sendCredit -= frameSize;
          sendFrames += 1;
          break;
        }
        waitUntil(deadline, "stream " + id + " send timed out waiting for credit");
      }
    }

    rawSend(payload);
  }

  /** Sends every chunk, then (by default) half-closes. */
  public void sendAll(Iterable<?> chunks, long timeoutMs, boolean halfClose)
      throws InterruptedException, StreamClosedException, StreamProtocolException, StreamTimeoutException {
    for (Object chunk : chunks) send(chunk, timeoutMs);
    if (halfClose) halfClose();
  }

  public void sendAll(Iterable<?> chunks)
      throws InterruptedException, StreamClosedException, StreamProtocolException, StreamTimeoutException {
    sendAll(chunks, -1, true);
  }

  /** Closes only this side's sending direction. Idempotent. */
  public void halfClose() {
    synchronized (this) {
      if (!outboundOpen || cancelled) return;
      outboundOpen = false;
      notifyAll();
    }
    emit(Arrays.asList(Protocol.HALF_CLOSE, id));
  }

  // -- peer events ----------------------------------------------------------

  public synchronized void addSendCredit(long bytes, long frames) {
    sendCredit = Math.min(sendCredit + bytes, maxCredit);
    sendFrames = Math.max(sendFrames - frames, 0);
    notifyAll();
  }

  public synchronized void peerHalfClosed() {
    inboundOpen = false;
    notifyAll();
  }

  /** Releases every piece of local state and unblocks the handler. */
  public synchronized void cancel() {
    cancelled = true;
    outboundOpen = false;
    inboundOpen = false;
    inbox.clear();
    notifyAll();
  }

  // -- internals ------------------------------------------------------------

  private long grantLocked() {
    long bytes = maxCredit - recvCredit - recvBytes;
    if (bytes <= 0) return 0;
    recvCredit += bytes;
    return bytes;
  }

  private static long deadlineFor(long timeoutMs) {
    return timeoutMs < 0 ? -1 : System.nanoTime() + timeoutMs * 1_000_000L;
  }

  // Must hold the monitor.
  private void waitUntil(long deadline, String message) throws InterruptedException, StreamTimeoutException {
    if (deadline < 0) {
      wait();
      return;
    }
    long remainingMs = (deadline - System.nanoTime()) / 1_000_000L;
    if (remainingMs <= 0) throw new StreamTimeoutException(message);
    wait(remainingMs);
  }

  private void emit(List<Object> envelope) {
    try {
      rawSend(encoder.encode(envelope));
    } catch (DecodeException e) {
      throw new IllegalStateException(e);
    }
  }

  private void rawSend(byte[] payload) {
    try {
      sendFrame.send(payload);
    } catch (RuntimeException e) {
      throw e;
    } catch (Exception e) {
      // The connection is gone; the worker's reader notices and cancels us.
    }
  }
}
