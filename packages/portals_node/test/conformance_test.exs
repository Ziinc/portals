defmodule PortalsNode.ConformanceTest do
  @moduledoc """
  Replays the protocol's golden vectors and malformed fixtures against the
  bundled Node SDK (see `Portals.Conformance.SDKSuite`).
  """

  @fixtures Path.expand("../priv/node/portals-worker/test/fixtures", __DIR__)

  use Portals.Conformance.SDKSuite,
    language: "node",
    worker: Portals.Node.worker_opts(script: Path.join(@fixtures, "run_worker.js")),
    stdio_worker: Portals.Node.worker_opts(script: Path.join(@fixtures, "run_worker_stdio.js")),
    bad_version_worker:
      Portals.Node.worker_opts(
        script: Path.join(@fixtures, "run_worker.js"),
        env: [{"PORTALS_PROTOCOL_VERSION", "999"}]
      )
end
