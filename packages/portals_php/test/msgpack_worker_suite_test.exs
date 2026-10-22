defmodule PortalsPHP.MsgpackWorkerSuiteTest do
  @moduledoc "The black-box worker suite again, over the MessagePack codec."

  @fixtures Path.expand("../priv/php/test/fixtures", __DIR__)

  use Portals.Conformance.WorkerSuite,
    worker:
      Portals.PHP.worker_opts(
        script: Path.join(@fixtures, "run_worker.php"),
        codec: :msgpack
      )
end
