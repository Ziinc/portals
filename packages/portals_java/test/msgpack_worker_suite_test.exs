defmodule PortalsJava.MsgpackWorkerSuiteTest do
  @moduledoc "The black-box worker suite again, over the MessagePack codec."

  use Portals.Conformance.WorkerSuite,
    worker:
      Portals.Java.worker_opts(
        main: "portals.fixtures.RunWorker",
        classpath: [PortalsJava.TestArtifacts.dir("fixtures")],
        java_args: PortalsJava.TestArtifacts.java_args(),
        codec: :msgpack
      )
end
