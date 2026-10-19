defmodule PortalsRuby.ConformanceTest do
  @moduledoc """
  Replays the protocol's golden vectors and malformed fixtures against the
  bundled Ruby SDK (see `Portals.Conformance.SDKSuite`).
  """

  @fixtures Path.expand("../priv/ruby/test/fixtures", __DIR__)

  use Portals.Conformance.SDKSuite,
    language: "ruby",
    worker: Portals.Ruby.worker_opts(script: Path.join(@fixtures, "run_worker.rb")),
    stdio_worker: Portals.Ruby.worker_opts(script: Path.join(@fixtures, "run_worker_stdio.rb")),
    bad_version_worker:
      Portals.Ruby.worker_opts(
        script: Path.join(@fixtures, "run_worker.rb"),
        env: [{"PORTALS_PROTOCOL_VERSION", "999"}]
      )
end
