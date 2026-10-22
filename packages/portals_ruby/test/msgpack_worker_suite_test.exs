defmodule PortalsRuby.MsgpackWorkerSuiteTest do
  @moduledoc "The black-box worker suite again, over the MessagePack codec."

  @fixtures Path.expand("../priv/ruby/test/fixtures", __DIR__)

  use Portals.Conformance.WorkerSuite,
    worker:
      Portals.Ruby.worker_opts(
        script: Path.join(@fixtures, "run_worker.rb"),
        codec: :msgpack
      )
end
