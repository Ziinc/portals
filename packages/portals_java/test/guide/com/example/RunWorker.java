package com.example;

import portals.Worker;

public final class RunWorker {
  private RunWorker() {}

  // Portals starts this class and appends the socket path as the last argument.
  public static void main(String[] args) throws Exception {
    new Worker()
        .maxConcurrency(8)
        .maxStreams(4)
        .register("text_tools", TextTools.class)
        .run(args);
    System.exit(0);
  }
}
