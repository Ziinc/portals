defmodule PortalsRuby.WorkerSuiteTest do
  @moduledoc """
  Holds the bundled Ruby SDK to the same black-box expectations as every
  other language (see `Portals.Conformance.WorkerSuite`), launching its
  fixture worker through `Portals.Ruby.worker_opts/1` exactly as an application
  would.
  """

  @fixtures Path.expand("../priv/ruby/test/fixtures", __DIR__)

  use Portals.Conformance.WorkerSuite,
    worker: Portals.Ruby.worker_opts(script: Path.join(@fixtures, "run_worker.rb"))
end
