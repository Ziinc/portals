defmodule PortalsGo.MsgpackWorkerSuiteTest do
  @moduledoc "The black-box worker suite again, over the MessagePack codec."

  use Portals.Conformance.WorkerSuite,
    worker:
      Portals.Go.worker_opts(
        binary: PortalsGo.TestArtifacts.binary("fixture_worker"),
        codec: :msgpack
      )
end
