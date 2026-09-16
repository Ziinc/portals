defmodule Portals.Integration.RubyWorkerTest do
  @moduledoc """
  Phase 7: the bundled Ruby SDK is held to exactly the same black-box
  expectations as the reference Python SDK (see
  `Portals.Fixtures.WorkerSuite`).
  """

  use Portals.Fixtures.WorkerSuite,
    runtime: "ruby",
    script: "sdk/ruby/test/fixtures/run_worker.rb"
end
