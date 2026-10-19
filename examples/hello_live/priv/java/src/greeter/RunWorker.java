package greeter;

import portals.Worker;

public final class RunWorker {
  private RunWorker() {}

  public static void main(String[] args) throws Exception {
    new Worker().register("greeter", Greeter.class).run(args);
    System.exit(0);
  }
}
