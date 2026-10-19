package portals.fixtures;

import portals.Protocol;
import portals.Worker;

/**
 * Entry point launched by Portals as the direct worker process (via
 * {@code run_worker.sh}; the socket path is appended as the final CLI
 * argument by {@code Portals.Connection}). Registers the fixture modules
 * under the names the BEAM uses in {@code CALL}, then runs the worker loop.
 */
public final class RunWorker {
  private RunWorker() {}

  public static void main(String[] args) {
    try {
      new Worker()
          .maxConcurrency(intEnv("PORTALS_MAX_CONCURRENCY", 64))
          .maxStreams(intEnv("PORTALS_MAX_STREAMS", 8))
          .protocolVersion(intEnv("PORTALS_PROTOCOL_VERSION", Protocol.PROTOCOL_VERSION))
          .transport("stdio".equals(System.getenv("PORTALS_TRANSPORT")) ? Worker.Transport.STDIO : Worker.Transport.UNIX)
          .register("bench_worker", BenchWorker.class)
          .register("conformance_worker", ConformanceWorker.class)
          .modulePackage("portals.fixtures")
          .run(args);
    } catch (Exception e) {
      System.err.println("portals worker: " + e);
      System.exit(1);
    }
    System.exit(0);
  }

  static int intEnv(String name, int fallback) {
    String value = System.getenv(name);
    return value == null || value.isEmpty() ? fallback : Integer.parseInt(value.trim());
  }
}
