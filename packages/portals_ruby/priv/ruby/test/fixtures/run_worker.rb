#!/usr/bin/env ruby
# frozen_string_literal: true

# Entry point launched by Portals as the direct worker process (the socket
# path is appended as the final CLI argument by `Portals.Connection`). Puts
# this fixtures directory on the load path so `bench_worker` is requirable,
# then runs the worker loop. `portals` itself is requirable because
# `Portals.Ruby.worker_opts/1` puts the SDK on `RUBYLIB`, exactly as for an
# application's worker.

here = File.expand_path(__dir__)
$LOAD_PATH.unshift(here)

require 'portals'
require 'bench_worker'
require 'conformance_worker'

Portals::Worker.new(
  max_concurrency: Integer(ENV.fetch('PORTALS_MAX_CONCURRENCY', '64')),
  max_streams: Integer(ENV.fetch('PORTALS_MAX_STREAMS', '8')),
  protocol_version: Integer(ENV.fetch('PORTALS_PROTOCOL_VERSION', Portals::Protocol::PROTOCOL_VERSION.to_s)),
  transport: ENV.fetch('PORTALS_TRANSPORT', 'unix').to_sym
).run
