defmodule PortalsGo.ConformanceTest do
  @moduledoc """
  Replays the protocol's golden vectors and malformed fixtures against the
  bundled Go SDK (see `Portals.Conformance.SDKSuite`).
  """

  use Portals.Conformance.SDKSuite,
    language: "go",
    worker: Portals.Go.worker_opts(binary: PortalsGo.TestArtifacts.binary("fixture_worker")),
    stdio_worker:
      Portals.Go.worker_opts(
        binary: PortalsGo.TestArtifacts.binary("fixture_worker"),
        env: [{"PORTALS_TRANSPORT", "stdio"}, {"PORTALS_MAX_CONCURRENCY", "16"}]
      ),
    bad_version_worker:
      Portals.Go.worker_opts(
        binary: PortalsGo.TestArtifacts.binary("fixture_worker"),
        env: [{"PORTALS_PROTOCOL_VERSION", "999"}]
      )
end
