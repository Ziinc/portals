// Command worker is the fixture worker launched by the Elixir integration
// and conformance suites (via ../run_worker.sh). It registers the
// bench_worker and conformance_worker modules — the Go mirror of
// packages/portals_python/priv/python/tests/fixtures/{bench_worker,conformance_worker}.py.
//
// Configuration comes from the environment, as in the other SDKs'
// fixtures: PORTALS_MAX_CONCURRENCY, PORTALS_MAX_STREAMS,
// PORTALS_PROTOCOL_VERSION and PORTALS_TRANSPORT.
package main

import (
	"fmt"
	"os"
	"strconv"

	portals "github.com/Ziinc/portals/sdk/go"
)

func envInt(name string, fallback int) int {
	if n, err := strconv.Atoi(os.Getenv(name)); err == nil {
		return n
	}
	return fallback
}

func main() {
	maxStreams := envInt("PORTALS_MAX_STREAMS", 8)
	if maxStreams == 0 {
		maxStreams = -1
	}
	w := portals.NewWorker(portals.Options{
		MaxConcurrency:  envInt("PORTALS_MAX_CONCURRENCY", 64),
		MaxStreams:      maxStreams,
		ProtocolVersion: envInt("PORTALS_PROTOCOL_VERSION", portals.ProtocolVersion),
		Transport:       os.Getenv("PORTALS_TRANSPORT"),
	})
	registerBenchWorker(w)
	registerConformanceWorker(w)

	if err := w.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "portals worker:", err)
		os.Exit(1)
	}
}
