defmodule PortalsJava.WorkerSuiteTest do
  @moduledoc """
  Holds the bundled Java SDK to the same black-box expectations as every
  other language (see `Portals.Conformance.WorkerSuite`), launching its
  fixture worker through `Portals.Java.worker_opts/1` exactly as an application
  would.
  """

  use Portals.Conformance.WorkerSuite,
    worker:
      Portals.Java.worker_opts(
        main: "portals.fixtures.RunWorker",
        classpath: [PortalsJava.TestArtifacts.dir("fixtures")],
        java_args: PortalsJava.TestArtifacts.java_args()
      )
end
