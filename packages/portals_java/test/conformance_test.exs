defmodule PortalsJava.ConformanceTest do
  @moduledoc """
  Replays the protocol's golden vectors and malformed fixtures against the
  bundled Java SDK (see `Portals.Conformance.SDKSuite`).
  """

  use Portals.Conformance.SDKSuite,
    language: "java",
    worker:
      Portals.Java.worker_opts(
        main: "portals.fixtures.RunWorker",
        classpath: [PortalsJava.TestArtifacts.dir("fixtures")],
        java_args: PortalsJava.TestArtifacts.java_args()
      ),
    stdio_worker:
      Portals.Java.worker_opts(
        main: "portals.fixtures.RunWorkerStdio",
        classpath: [PortalsJava.TestArtifacts.dir("fixtures")],
        java_args: PortalsJava.TestArtifacts.java_args()
      ),
    bad_version_worker:
      Portals.Java.worker_opts(
        main: "portals.fixtures.RunWorker",
        classpath: [PortalsJava.TestArtifacts.dir("fixtures")],
        java_args: PortalsJava.TestArtifacts.java_args(),
        env: [{"PORTALS_PROTOCOL_VERSION", "999"}]
      )
end
