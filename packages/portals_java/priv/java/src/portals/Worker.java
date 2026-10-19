package portals;

import java.io.FileOutputStream;
import java.io.IOException;
import java.io.PrintStream;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import java.util.function.Consumer;

/**
 * The Java worker runtime: connects to the BEAM's Unix socket, completes the
 * exact-version handshake, and dispatches {@code CALL} frames to arbitrary
 * module/function targets concurrently.
 *
 * <pre>{@code
 * public static void main(String[] args) throws Exception {
 *   new Worker().register("my_handlers", MyHandlers.class).run(args);
 * }
 * }</pre>
 *
 * <p>The socket reader is the thread that called {@link #run}, and it never
 * executes a handler: each {@code CALL} is handed to a bounded thread pool,
 * so a slow or blocked handler can never stall reading further frames or
 * responding to other in-flight calls. Streams run on their own pool sized
 * by {@code max_streams}, so long-lived streams cannot consume unary
 * capacity.
 *
 * <p>Fully reentrant callbacks (protocol/v1.md §8): a handler may call back
 * into the BEAM with {@link Portals#callback}, which blocks the handler's
 * own thread (never the reader), so a nested {@code CALL} dispatched back
 * into this same worker while the callback is outstanding is still served
 * by another pool thread.
 */
public final class Worker {
  public static final int DEFAULT_MAX_CONCURRENCY = 16;
  public static final int DEFAULT_MAX_STREAMS = 8;

  /** Which framed transport {@link #run} uses. */
  public enum Transport {
    UNIX,
    STDIO
  }

  private static volatile Worker active;

  private int maxConcurrency = DEFAULT_MAX_CONCURRENCY;
  private int maxStreams = DEFAULT_MAX_STREAMS;
  private String socketPath;
  private Transport transport = Transport.UNIX;
  private long protocolVersion = Protocol.PROTOCOL_VERSION;
  private Consumer<String> logger;
  private final List<String> modulePackages = new ArrayList<>();

  private final Map<String, Object> modules = new ConcurrentHashMap<>();
  private final Map<String, Map<String, Target>> functions = new ConcurrentHashMap<>();
  private final Map<String, Target> targetCache = new ConcurrentHashMap<>();

  private volatile Limits limits = Limits.DEFAULT;
  private FramedConnection conn;
  private ExecutorService callPool;
  private ExecutorService streamPool;
  private volatile boolean shutdown;

  private final Object streamsLock = new Object();
  private final Map<Object, Stream> streams = new HashMap<>();
  private final Map<Object, CallContext> pendingUnary = new ConcurrentHashMap<>();

  private final AtomicLong callbackIds = new AtomicLong();
  private final Map<Long, CompletableFuture<Object>> pendingCallbacks = new ConcurrentHashMap<>();

  /** Per-call context visible to the handler's thread. */
  static final class CallContext {
    final long depth;
    final Long deadlineMs;
    final AtomicBoolean cancelled = new AtomicBoolean();

    CallContext(long depth, Long deadlineMs) {
      this.depth = depth;
      this.deadlineMs = deadlineMs;
    }
  }

  static final ThreadLocal<CallContext> CONTEXT = new ThreadLocal<>();

  // -- Configuration --------------------------------------------------------

  /** Concurrently executing unary calls, advertised in {@code HELLO}. */
  public Worker maxConcurrency(int value) {
    if (value <= 0) throw new IllegalArgumentException("maxConcurrency must be positive");
    this.maxConcurrency = value;
    return this;
  }

  /** Concurrently open streams, advertised in {@code HELLO}; 0 disables streaming. */
  public Worker maxStreams(int value) {
    if (value < 0) throw new IllegalArgumentException("maxStreams must not be negative");
    this.maxStreams = value;
    return this;
  }

  public Worker socketPath(String path) {
    this.socketPath = path;
    return this;
  }

  public Worker transport(Transport value) {
    this.transport = value;
    return this;
  }

  /**
   * Overridable strictly so the version-mismatch diagnostics can be
   * exercised end to end; real workers always send the SDK's version.
   */
  public Worker protocolVersion(long version) {
    this.protocolVersion = version;
    return this;
  }

  /** Where log lines go. Never over the RPC protocol. */
  public Worker logger(Consumer<String> value) {
    this.logger = value;
    return this;
  }

  /**
   * Packages searched for a class named after an unregistered wire module
   * ({@code "bench_worker"} → {@code <package>.BenchWorker}).
   */
  public Worker modulePackage(String packageName) {
    modulePackages.add(packageName);
    return this;
  }

  /**
   * Registers a module under the name the BEAM will use in {@code CALL}.
   * A {@link Class} exposes its public static methods; any other object
   * exposes its public instance and static methods.
   */
  public Worker register(String name, Object module) {
    modules.put(name, module);
    targetCache.keySet().removeIf(key -> key.startsWith(name + "\0"));
    return this;
  }

  /** Registers a single unary function directly. */
  public Worker function(String module, String function, Handler handler) {
    functions.computeIfAbsent(module, k -> new ConcurrentHashMap<>())
        .put(function, new LambdaTarget(handler, null));
    return this;
  }

  /** Registers a single streaming function directly. */
  public Worker streamFunction(String module, String function, StreamFunction handler) {
    functions.computeIfAbsent(module, k -> new ConcurrentHashMap<>())
        .put(function, new LambdaTarget(null, handler));
    return this;
  }

  public Limits limits() {
    return limits;
  }

  static Worker active() {
    return active;
  }

  // -- Running --------------------------------------------------------------

  /**
   * Connects, handshakes, and serves frames until the BEAM closes the
   * connection or sends {@code SHUTDOWN}. For the Unix transport the socket
   * path defaults to the last of {@code args}, which is where
   * {@code Portals.Connection} appends it.
   */
  public void run(String... args) throws IOException {
    if (logger == null) logger = defaultLogger();

    if (transport == Transport.STDIO) {
      conn = FramedConnection.stdio();
    } else {
      String path = socketPath;
      if (path == null) {
        if (args.length == 0) {
          throw new IllegalArgumentException("portals worker: expected the socket path as the last argument");
        }
        path = args[args.length - 1];
      }
      conn = FramedConnection.connectUnix(path);
    }

    try {
      handshake();
    } catch (IOException | RuntimeException e) {
      conn.close();
      throw e;
    }

    callPool = newPool(maxConcurrency, "portals-call");
    streamPool = maxStreams > 0 ? newPool(maxStreams, "portals-stream") : null;
    active = this;

    try {
      while (!shutdown) {
        byte[] payload;
        try {
          // Slack for the codec's own (precise) max_frame_size check.
          payload = conn.recvFrame(limits.maxFrameSize() + 1);
        } catch (IOException e) {
          if (!conn.isClosed()) log("portals worker: connection lost: " + e.getMessage());
          break;
        }
        if (payload == null) break;
        handleFrame(payload);
      }
    } finally {
      if (active == this) active = null;
      cancelAllStreams();
      failPendingCallbacks();
      callPool.shutdown();
      if (streamPool != null) streamPool.shutdown();
      if (shutdown) {
        // Let already-running handlers flush their terminal frames.
        awaitQuietly(callPool);
        if (streamPool != null) awaitQuietly(streamPool);
      }
      conn.close();
    }
  }

  private static void awaitQuietly(ExecutorService pool) {
    try {
      pool.awaitTermination(2, TimeUnit.SECONDS);
    } catch (InterruptedException e) {
      Thread.currentThread().interrupt();
    }
  }

  private static ExecutorService newPool(int size, String name) {
    AtomicInteger counter = new AtomicInteger();
    return new ThreadPoolExecutor(size, size, 0L, TimeUnit.MILLISECONDS, new LinkedBlockingQueue<>(), runnable -> {
      Thread thread = new Thread(runnable, name + "-" + counter.getAndIncrement());
      thread.setDaemon(true);
      return thread;
    });
  }

  static Consumer<String> defaultLogger() {
    String path = System.getenv("PORTALS_LOG_FILE");
    if (path != null && !path.isEmpty()) {
      try {
        PrintStream file = new PrintStream(new FileOutputStream(path, true), true, StandardCharsets.UTF_8);
        return message -> file.println(message);
      } catch (IOException e) {
        System.err.println("portals worker: cannot open PORTALS_LOG_FILE " + path + ": " + e.getMessage());
      }
    }
    // Captured as System.err up front: the stdio transport repoints System.out.
    PrintStream err = System.err;
    return err::println;
  }

  private void log(String message) {
    logger.accept(message);
  }

  // -- Handshake ------------------------------------------------------------

  void handshake() throws IOException {
    List<Object> hello = Arrays.asList(
        Protocol.HELLO,
        protocolVersion,
        "java" + Runtime.version().feature(),
        maxConcurrency,
        maxStreams,
        List.of());
    try {
      conn.sendFrame(MsgpackCodec.encode(hello, limits));
    } catch (DecodeException e) {
      throw new ProtocolException("cannot encode HELLO: " + e.getMessage());
    }

    byte[] payload = conn.recvFrame();
    if (payload == null) throw new ConnectionClosedException("connection closed during handshake");

    List<Object> envelope;
    try {
      envelope = MsgpackCodec.decodeEnvelope(payload, limits);
    } catch (DecodeException e) {
      throw new ProtocolException("malformed READY: " + e.getMessage());
    }

    Object tag = envelope.get(0);
    if (!numberEquals(tag, Protocol.READY)) throw new ProtocolException("expected READY, got frame tag " + tag);

    Object version = field(envelope, 1);
    if (!numberEquals(version, Protocol.PROTOCOL_VERSION)) {
      throw new ProtocolException(
          "protocol version mismatch: worker=" + Protocol.PROTOCOL_VERSION + " beam=" + version);
    }

    if (field(envelope, 2) instanceof Map<?, ?> overrides) limits = limits.merge(overrides);
  }

  // -- Reentrant callbacks and messaging ------------------------------------

  Object callCallback(String module, String function, List<?> args, long timeoutMs) throws InterruptedException {
    long depth = currentCallbackDepth() + 1;
    long id = callbackIds.incrementAndGet();
    CompletableFuture<Object> future = new CompletableFuture<>();
    pendingCallbacks.put(id, future);

    sendEnvelope(Arrays.asList(Protocol.CALLBACK, id, module, function, args == null ? List.of() : args, depth));

    try {
      return timeoutMs < 0 ? future.get() : future.get(timeoutMs, TimeUnit.MILLISECONDS);
    } catch (TimeoutException e) {
      throw new CallbackTimeoutException("callback " + module + "." + function + " timed out");
    } catch (ExecutionException e) {
      if (e.getCause() instanceof RuntimeException runtime) throw runtime;
      throw new PortalsException("callback failed", e.getCause());
    } finally {
      pendingCallbacks.remove(id);
    }
  }

  void sendMessage(Object targetPid, Object value) {
    sendEnvelope(Arrays.asList(Protocol.MESSAGE, targetPid, value));
  }

  private void resolveCallback(Object id, boolean ok, Object value) {
    CompletableFuture<Object> future = id instanceof Long key ? pendingCallbacks.remove(key) : null;
    if (future == null) {
      log("portals worker: unknown callback_id " + id + " in response");
      return;
    }
    if (ok) {
      future.complete(value);
    } else {
      future.completeExceptionally(new RemoteException(value instanceof Map<?, ?> map ? map : Map.of()));
    }
  }

  private void failPendingCallbacks() {
    for (CompletableFuture<Object> future : pendingCallbacks.values()) {
      future.completeExceptionally(new PortalsException("connection closed"));
    }
    pendingCallbacks.clear();
  }

  static long currentCallbackDepth() {
    CallContext context = CONTEXT.get();
    return context == null ? 0 : context.depth;
  }

  // -- Frame dispatch -------------------------------------------------------

  void handleFrame(byte[] payload) {
    List<Object> envelope;
    try {
      envelope = MsgpackCodec.decodeEnvelope(payload, limits);
    } catch (DecodeException e) {
      log("portals worker: dropping malformed frame: " + e.getMessage());
      return;
    }

    if (!(envelope.get(0) instanceof Long tag)) {
      log("portals worker: dropping frame with a non-integer tag");
      return;
    }
    long frameSize = payload.length + Stream.FRAME_PREFIX_BYTES;

    switch (tag.intValue()) {
      case Protocol.CALL -> submitCall(envelope.subList(1, envelope.size()));
      case Protocol.CANCEL -> cancelRequest(field(envelope, 1));
      case Protocol.STREAM_DATA -> handleStreamData(field(envelope, 1), field(envelope, 2), frameSize);
      case Protocol.CREDIT -> {
        Stream stream = findStream(field(envelope, 1));
        if (stream != null) {
          long bytes = asLong(field(envelope, 2), 0);
          long frames = envelope.size() > 3 ? asLong(field(envelope, 3), 0) : 1;
          stream.addSendCredit(bytes, frames);
        }
      }
      case Protocol.HALF_CLOSE -> {
        Stream stream = findStream(field(envelope, 1));
        if (stream != null) stream.peerHalfClosed();
      }
      case Protocol.CALLBACK_RETURN -> resolveCallback(field(envelope, 1), true, field(envelope, 2));
      case Protocol.CALLBACK_ERROR -> resolveCallback(field(envelope, 1), false, field(envelope, 2));
      case Protocol.PING -> sendEnvelope(Arrays.asList(Protocol.PONG, field(envelope, 1)));
      case Protocol.PONG -> { }
      case Protocol.SHUTDOWN -> shutdown = true;
      default -> log("portals worker: ignoring unsupported frame tag " + tag);
    }
  }

  // -- Dispatch -------------------------------------------------------------

  /**
   * Routes a CALL to the unary pool, or — when its target is a stream
   * handler — to the separate stream pool with a {@link Stream} bound to
   * the call's request_id.
   */
  private void submitCall(List<Object> fields) {
    Object requestId = field(fields, 0);
    String module = String.valueOf(field(fields, 1));
    String function = String.valueOf(field(fields, 2));
    List<Object> args = field(fields, 3) instanceof List<?> list ? castList(list) : List.of();
    Long deadlineMs = field(fields, 4) instanceof Number n ? n.longValue() : null;
    long depth = asLong(field(fields, 5), 0);

    Target target = resolveQuietly(module, function);

    if (target == null || !target.isStream()) {
      CallContext context = new CallContext(depth, deadlineMs);
      pendingUnary.put(requestId, context);
      callPool.execute(() -> runUnary(requestId, module, function, args, context));
      return;
    }

    if (streamPool == null) {
      sendEnvelope(Arrays.asList(Protocol.ERROR, requestId, Errors.overloadErrorMap("worker advertises no streams")));
      return;
    }

    Stream stream;
    synchronized (streamsLock) {
      if (streams.size() >= maxStreams) {
        stream = null;
      } else {
        stream = new Stream(
            requestId,
            limits.maxStreamByteCredit(),
            limits.maxQueuedStreamFrames(),
            bytes -> conn.sendFrame(bytes),
            envelope -> MsgpackCodec.encode(envelope, limits));
        streams.put(requestId, stream);
      }
    }

    if (stream == null) {
      sendEnvelope(Arrays.asList(Protocol.ERROR, requestId, Errors.overloadErrorMap("max_streams exceeded")));
      return;
    }

    long grant = stream.initialGrant();
    if (grant > 0) sendEnvelope(Arrays.asList(Protocol.CREDIT, requestId, grant, 0));

    CallContext context = new CallContext(depth, deadlineMs);
    streamPool.execute(() -> runStream(stream, target, args, context));
  }

  private void runUnary(Object requestId, String module, String function, List<Object> args, CallContext context) {
    CONTEXT.set(context);
    try {
      Object result = resolveTarget(module, function).invoke(null, args);
      respond(requestId, result);
    } catch (Throwable e) {
      sendEnvelope(Arrays.asList(Protocol.ERROR, requestId, Errors.buildErrorMap(e)));
    } finally {
      pendingUnary.remove(requestId);
      CONTEXT.remove();
    }
  }

  private void runStream(Stream stream, Target target, List<Object> args, CallContext context) {
    Object requestId = stream.id();
    CONTEXT.set(context);
    try {
      Object result = target.invoke(stream, args);
      stream.halfClose();
      releaseStream(requestId);
      if (!stream.isCancelled()) respond(requestId, result);
    } catch (Throwable e) {
      releaseStream(requestId);
      if (!stream.isCancelled()) sendEnvelope(Arrays.asList(Protocol.ERROR, requestId, Errors.buildErrorMap(e)));
    } finally {
      CONTEXT.remove();
    }
  }

  // A result that cannot be encoded still owes the caller a terminal frame.
  private void respond(Object requestId, Object result) {
    byte[] bytes;
    try {
      bytes = MsgpackCodec.encode(Arrays.asList(Protocol.RETURN, requestId, result), limits);
    } catch (DecodeException e) {
      Map<String, Object> error = Errors.buildErrorMap(e);
      error.put("message", "return value cannot be encoded: " + e.getMessage());
      sendEnvelope(Arrays.asList(Protocol.ERROR, requestId, error));
      return;
    }
    sendBytes(bytes);
  }

  // -- Cancellation and streaming -------------------------------------------

  /**
   * {@code CANCEL} shares the request_id space with streams: it cancels the
   * stream outright, or raises the cooperative cancellation flag for an
   * in-flight unary call (never a forced kill).
   */
  private void cancelRequest(Object requestId) {
    Stream stream = findStream(requestId);
    if (stream != null) {
      stream.cancel();
      releaseStream(requestId);
      return;
    }
    CallContext context = pendingUnary.get(requestId);
    if (context != null) context.cancelled.set(true);
  }

  private void handleStreamData(Object streamId, Object chunk, long frameSize) {
    Stream stream = findStream(streamId);
    if (stream == null) return;
    try {
      stream.recordInbound(chunk, frameSize);
    } catch (StreamProtocolException e) {
      // A peer that exceeds its allowance loses only that stream.
      stream.cancel();
      releaseStream(streamId);
      sendEnvelope(Arrays.asList(Protocol.ERROR, streamId, Errors.protocolErrorMap(e.getMessage())));
    }
  }

  private Stream findStream(Object streamId) {
    synchronized (streamsLock) {
      return streams.get(streamId);
    }
  }

  private void releaseStream(Object streamId) {
    synchronized (streamsLock) {
      streams.remove(streamId);
    }
  }

  private void cancelAllStreams() {
    List<Stream> open;
    synchronized (streamsLock) {
      open = new ArrayList<>(streams.values());
      streams.clear();
    }
    for (Stream stream : open) stream.cancel();
  }

  void sendEnvelope(List<Object> envelope) {
    try {
      sendBytes(MsgpackCodec.encode(envelope, limits));
    } catch (DecodeException e) {
      log("portals worker: cannot encode frame: " + e.getMessage());
    }
  }

  private void sendBytes(byte[] bytes) {
    try {
      conn.sendFrame(bytes);
    } catch (IOException e) {
      log("portals worker: send failed: " + e.getMessage());
    }
  }

  // -- Target resolution ----------------------------------------------------

  /** A resolved {@code module.function}. */
  interface Target {
    boolean isStream();

    Object invoke(Stream stream, List<Object> args) throws Exception;
  }

  private record LambdaTarget(Handler unary, StreamFunction streaming) implements Target {
    @Override
    public boolean isStream() {
      return streaming != null;
    }

    @Override
    public Object invoke(Stream stream, List<Object> args) throws Exception {
      return streaming != null ? streaming.call(stream, args) : unary.call(args);
    }
  }

  /** Every public method of a module with a matching wire name, tried by arity. */
  private record MethodTarget(Object receiver, List<Method> methods, boolean isStream) implements Target {
    @Override
    public Object invoke(Stream stream, List<Object> args) throws Exception {
      int offset = isStream ? 1 : 0;
      IllegalArgumentException mismatch = null;
      for (Method method : methods) {
        Class<?>[] types = method.getParameterTypes();
        if (types.length != args.size() + offset) continue;
        Object[] actual = new Object[types.length];
        if (isStream) actual[0] = stream;
        try {
          for (int i = 0; i < args.size(); i++) actual[i + offset] = coerce(args.get(i), types[i + offset], i);
        } catch (IllegalArgumentException e) {
          mismatch = e;
          continue;
        }
        Object target = Modifier.isStatic(method.getModifiers()) ? null : receiver;
        return method.invoke(target, actual);
      }
      if (mismatch != null) throw mismatch;
      throw new IllegalArgumentException(
          methods.get(0).getName() + " does not accept " + args.size() + " argument(s)");
    }
  }

  private Target resolveQuietly(String module, String function) {
    try {
      return resolveTarget(module, function);
    } catch (Exception e) {
      // An unresolvable target is reported properly by the unary path.
      return null;
    }
  }

  Target resolveTarget(String module, String function) throws ReflectiveOperationException {
    Map<String, Target> direct = functions.get(module);
    if (direct != null && direct.containsKey(function)) return direct.get(function);

    String key = module + "\0" + function;
    Target cached = targetCache.get(key);
    if (cached != null) return cached;

    Object receiver = resolveModule(module);
    Class<?> type = receiver instanceof Class<?> c ? c : receiver.getClass();
    boolean staticOnly = receiver instanceof Class<?>;
    String camel = camelCase(function);

    List<Method> methods = new ArrayList<>();
    for (Method method : type.getMethods()) {
      if (method.getDeclaringClass() == Object.class) continue;
      if (!method.getName().equals(function) && !method.getName().equals(camel)) continue;
      if (staticOnly && !Modifier.isStatic(method.getModifiers())) continue;
      method.trySetAccessible();
      methods.add(method);
    }
    if (methods.isEmpty()) throw new NoSuchMethodException("no such function " + module + "." + function);

    boolean stream = false;
    for (Method method : methods) {
      if (method.isAnnotationPresent(StreamHandler.class)) stream = true;
    }
    if (stream) {
      methods.removeIf(m -> !m.isAnnotationPresent(StreamHandler.class)
          || m.getParameterCount() == 0
          || m.getParameterTypes()[0] != Stream.class);
      if (methods.isEmpty()) {
        throw new NoSuchMethodException(module + "." + function + ": a @StreamHandler must take a Stream first");
      }
    }
    // Fewer parameters first, so overloads behave like default arguments.
    methods.sort((a, b) -> Integer.compare(a.getParameterCount(), b.getParameterCount()));

    Target target = new MethodTarget(staticOnly ? null : receiver, Collections.unmodifiableList(methods), stream);
    targetCache.put(key, target);
    return target;
  }

  private Object resolveModule(String name) throws ClassNotFoundException {
    Object registered = modules.get(name);
    if (registered != null) return registered;

    List<String> candidates = new ArrayList<>();
    candidates.add(name);
    for (String pkg : modulePackages) {
      candidates.add(pkg + "." + pascalCase(name));
      candidates.add(pkg + "." + name);
    }
    for (String candidate : candidates) {
      try {
        Class<?> found = Class.forName(candidate);
        modules.put(name, found);
        return found;
      } catch (ClassNotFoundException | NoClassDefFoundError ignored) {
        // Try the next candidate.
      }
    }
    throw new ClassNotFoundException("no such module " + name);
  }

  static String camelCase(String name) {
    String pascal = pascalCase(name);
    return pascal.isEmpty() ? pascal : Character.toLowerCase(pascal.charAt(0)) + pascal.substring(1);
  }

  static String pascalCase(String name) {
    StringBuilder out = new StringBuilder();
    for (String part : name.split("_")) {
      if (part.isEmpty()) continue;
      out.append(Character.toUpperCase(part.charAt(0))).append(part.substring(1));
    }
    return out.toString();
  }

  /** Adapts a decoded wire value to a handler's declared parameter type. */
  static Object coerce(Object value, Class<?> type, int index) {
    if (value == null) {
      if (type.isPrimitive()) throw new IllegalArgumentException("argument " + index + " must not be nil");
      return null;
    }
    if (type.isInstance(value)) return value;
    if (value instanceof Number number) {
      boolean integral = Values.isInteger(value);
      if ((type == long.class || type == Long.class) && integral && fits(number, Long.MIN_VALUE, Long.MAX_VALUE)) {
        return number.longValue();
      }
      if ((type == int.class || type == Integer.class) && integral && fits(number, Integer.MIN_VALUE, Integer.MAX_VALUE)) {
        return number.intValue();
      }
      if ((type == short.class || type == Short.class) && integral && fits(number, Short.MIN_VALUE, Short.MAX_VALUE)) {
        return number.shortValue();
      }
      if ((type == byte.class || type == Byte.class) && integral && fits(number, Byte.MIN_VALUE, Byte.MAX_VALUE)) {
        return number.byteValue();
      }
      if (type == double.class || type == Double.class) return number.doubleValue();
      if (type == float.class || type == Float.class) return number.floatValue();
      if (type == BigInteger.class && integral) return Values.toBigInteger(number);
    }
    if (value instanceof Boolean && type == boolean.class) return value;
    if (value instanceof byte[] bytes && type == String.class) return new String(bytes, StandardCharsets.UTF_8);
    if (value instanceof String text && type == byte[].class) return text.getBytes(StandardCharsets.UTF_8);
    if (value instanceof Atom atom && type == String.class) return atom.name();
    throw new IllegalArgumentException(
        "argument " + index + ": expected " + type.getSimpleName() + ", got " + value.getClass().getSimpleName());
  }

  private static boolean fits(Number number, long min, long max) {
    BigInteger value = Values.toBigInteger(number);
    return value.compareTo(BigInteger.valueOf(min)) >= 0 && value.compareTo(BigInteger.valueOf(max)) <= 0;
  }

  // -- Small helpers ---------------------------------------------------------

  private static Object field(List<Object> list, int index) {
    return index < list.size() ? list.get(index) : null;
  }

  @SuppressWarnings("unchecked")
  private static List<Object> castList(List<?> list) {
    return (List<Object>) list;
  }

  private static long asLong(Object value, long fallback) {
    return value instanceof Number number ? number.longValue() : fallback;
  }

  private static boolean numberEquals(Object value, long expected) {
    return value instanceof Long number && number == expected;
  }
}
