defmodule PortalsPython.MsgpackWorkerSuiteTest do
  @moduledoc "The black-box worker suite again, over the MessagePack codec."

  @fixtures Path.expand("../priv/python/tests/fixtures", __DIR__)

  use Portals.Conformance.WorkerSuite,
    worker:
      Portals.Python.worker_opts(
        script: Path.join(@fixtures, "run_worker.py"),
        codec: :msgpack
      )
end
