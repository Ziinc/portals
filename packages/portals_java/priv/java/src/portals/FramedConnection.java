package portals;

import java.io.EOFException;
import java.io.FileDescriptor;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.PrintStream;
import java.net.StandardProtocolFamily;
import java.net.UnixDomainSocketAddress;
import java.nio.ByteBuffer;
import java.nio.channels.SocketChannel;
import java.nio.file.Path;

/**
 * Length-framed transport for the Java worker side.
 *
 * <p>Matches the BEAM's {@code {:packet, 4}} framing exactly: a 4-byte
 * big-endian length prefix followed by that many bytes of
 * envelope encoded with the selected {@link Codec}. Reads happen on a single reader thread;
 * writes may come from any handler thread and are serialized so frames
 * never interleave.
 */
public final class FramedConnection implements AutoCloseable {
  private final Reader reader;
  private final Writer writer;
  private final AutoCloseable closer;
  private final Object writeLock = new Object();
  private volatile boolean closed;

  interface Reader {
    /** Fills {@code buffer} completely; returns false on EOF before any byte. */
    boolean readFully(ByteBuffer buffer) throws IOException;
  }

  interface Writer {
    void write(ByteBuffer buffer) throws IOException;
  }

  private FramedConnection(Reader reader, Writer writer, AutoCloseable closer) {
    this.reader = reader;
    this.writer = writer;
    this.closer = closer;
  }

  /**
   * Connects to the BEAM's per-worker Unix-domain socket. Uses the channel
   * directly (not {@code Channels.newInputStream}) so a blocked read never
   * holds a lock a concurrent writer needs.
   */
  public static FramedConnection connectUnix(String path) throws IOException {
    SocketChannel channel = SocketChannel.open(StandardProtocolFamily.UNIX);
    channel.connect(UnixDomainSocketAddress.of(Path.of(path)));
    Reader reader = buffer -> {
      while (buffer.hasRemaining()) {
        if (channel.read(buffer) < 0) {
          if (buffer.position() == 0) return false;
          throw new ConnectionClosedException("connection closed mid-frame");
        }
      }
      return true;
    };
    Writer writer = buffer -> {
      while (buffer.hasRemaining()) channel.write(buffer);
    };
    return new FramedConnection(reader, writer, channel);
  }

  /**
   * The framed stdio fallback transport. Takes over the process's real
   * stdout for frames and points {@code System.out} at stderr, so a stray
   * {@code println} in user code can never corrupt the protocol stream.
   */
  public static FramedConnection stdio() {
    InputStream in = new FileInputStream(FileDescriptor.in);
    OutputStream out = new FileOutputStream(FileDescriptor.out);
    System.setOut(new PrintStream(new FileOutputStream(FileDescriptor.err), true));
    return fromStreams(in, out);
  }

  public static FramedConnection fromStreams(InputStream in, OutputStream out) {
    Reader reader = buffer -> {
      int start = buffer.position();
      while (buffer.hasRemaining()) {
        int n = in.read(buffer.array(), buffer.arrayOffset() + buffer.position(), buffer.remaining());
        if (n < 0) {
          if (buffer.position() == start) return false;
          throw new ConnectionClosedException("connection closed mid-frame");
        }
        buffer.position(buffer.position() + n);
      }
      return true;
    };
    Writer writer = buffer -> {
      out.write(buffer.array(), buffer.arrayOffset() + buffer.position(), buffer.remaining());
      out.flush();
      buffer.position(buffer.limit());
    };
    return new FramedConnection(reader, writer, () -> {
      in.close();
      out.close();
    });
  }

  public void sendFrame(byte[] payload) throws IOException {
    if (closed) throw new ConnectionClosedException("connection closed");
    ByteBuffer frame = ByteBuffer.allocate(4 + payload.length);
    frame.putInt(payload.length).put(payload).flip();
    synchronized (writeLock) {
      writer.write(frame);
    }
  }

  /** The next complete envelope, or {@code null} once the peer closed cleanly. */
  public byte[] recvFrame() throws IOException {
    return recvFrame(Integer.MAX_VALUE - 8);
  }

  /**
   * Like {@link #recvFrame()}, but a length prefix above {@code maxSize} is
   * fatal for the connection rather than an attempt to buffer it.
   */
  public byte[] recvFrame(long maxSize) throws IOException {
    ByteBuffer header = ByteBuffer.allocate(4);
    try {
      if (!reader.readFully(header)) return null;
    } catch (EOFException e) {
      return null;
    }
    header.flip();
    long length = header.getInt() & 0xffffffffL;
    if (length > Math.min(maxSize, Integer.MAX_VALUE - 8)) {
      throw new IOException("frame of " + length + " bytes exceeds the maximum of " + maxSize);
    }
    ByteBuffer body = ByteBuffer.allocate((int) length);
    if (length > 0 && !reader.readFully(body)) throw new ConnectionClosedException("connection closed mid-frame");
    return body.array();
  }

  public boolean isClosed() {
    return closed;
  }

  @Override
  public void close() {
    if (closed) return;
    closed = true;
    try {
      closer.close();
    } catch (Exception ignored) {
      // Closing an already-dead socket is not an error.
    }
  }
}
