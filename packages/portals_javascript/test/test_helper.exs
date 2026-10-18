# Every suite runs once per JavaScript runtime. A runtime whose executable
# is missing is excluded with a notice, unless PORTALS_REQUIRE_ALL_RUNTIMES=1
# (as in CI), which makes a missing runtime fail the run instead.
executables = %{node: "node", bun: "bun", deno: "deno", quickjs: "qjs"}

missing =
  for {runtime, executable} <- executables,
      is_nil(System.find_executable(executable)),
      do: runtime

if missing != [] and System.get_env("PORTALS_REQUIRE_ALL_RUNTIMES") == "1" do
  raise "JavaScript runtimes not on PATH: #{inspect(missing)}"
end

for runtime <- missing do
  IO.puts(:stderr, "Skipping the #{runtime} suites: `#{executables[runtime]}` is not on PATH")
end

ExUnit.start(exclude: Enum.map(missing, &{:runtime, &1}))

# Callback targets must already exist as atoms before a worker can name them
# (protocol/v1.md section 5.3); the shared suites call back into this one.
Code.ensure_loaded!(Portals.Fixtures.CallbackTarget)
