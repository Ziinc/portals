package portals.fixtures;

import portals.Worker;

/** Same worker as {@link RunWorker}, over the framed stdio fallback transport. */
public final class RunWorkerStdio {
  private RunWorkerStdio() {}

  public static void main(String[] args) {
    try {
      new Worker()
          .maxConcurrency(16)
          .maxStreams(8)
          .transport(Worker.Transport.STDIO)
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
}
