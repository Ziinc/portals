defmodule PortalsPHP.ConformanceTest do
  @moduledoc """
  Replays the protocol's golden vectors and malformed fixtures against the
  bundled PHP SDK (see `Portals.Conformance.SDKSuite`).
  """

  @fixtures Path.expand("../priv/php/test/fixtures", __DIR__)

  use Portals.Conformance.SDKSuite,
    language: "php",
    worker: Portals.PHP.worker_opts(script: Path.join(@fixtures, "run_worker.php")),
    stdio_worker: Portals.PHP.worker_opts(script: Path.join(@fixtures, "run_worker_stdio.php")),
    bad_version_worker:
      Portals.PHP.worker_opts(
        script: Path.join(@fixtures, "run_worker.php"),
        env: [{"PORTALS_PROTOCOL_VERSION", "999"}]
      )
end
