ExUnit.start()

# The atom-safety model (protocol/v1.md section 5.3) means a callback
# target's module/function atoms must already exist in the runtime before
# a CALLBACK frame naming them can be accepted. In a real application
# these atoms exist simply because the application's own code refers to
# the callback module; here we force that ahead of the integration tests
# that exercise Portals.Fixtures.CallbackTarget as a callback target.
Code.ensure_loaded!(Portals.Fixtures.CallbackTarget)

# Compiled SDKs: build their fixture workers once up front, so the first
# integration tests to launch one do not race its build against the
# connect timeout. (Each launcher still rebuilds on demand when stale.)
if System.find_executable("go") do
  {_, 0} = System.cmd("sh", ["sdk/go/test/fixtures/run_worker.sh", "--build-only"])
end
