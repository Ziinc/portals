ExUnit.start()

# Callback targets must already exist as atoms before a worker can name them
# (protocol/v1.md section 5.3); the shared suites call back into this one.
Code.ensure_loaded!(Portals.Fixtures.CallbackTarget)
