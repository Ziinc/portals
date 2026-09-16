#!/usr/bin/env ruby
# frozen_string_literal: true

# Entry point launched by Portals as the direct worker process (the socket
# path is appended as the final CLI argument by `Portals.Connection`). Puts
# this fixtures directory and the SDK's `lib` on the load path so both
# `bench_worker` and `portals` are requirable, then runs the worker loop.

here = File.expand_path(__dir__)
$LOAD_PATH.unshift(here)
$LOAD_PATH.unshift(File.expand_path('../../lib', here))

require 'portals'
require 'bench_worker'
require 'conformance_worker'

Portals::Worker.new(
  max_concurrency: Integer(ENV.fetch('PORTALS_MAX_CONCURRENCY', '64')),
  max_streams: Integer(ENV.fetch('PORTALS_MAX_STREAMS', '8')),
  protocol_version: Integer(ENV.fetch('PORTALS_PROTOCOL_VERSION', Portals::Protocol::PROTOCOL_VERSION.to_s)),
  transport: ENV.fetch('PORTALS_TRANSPORT', 'unix').to_sym
).run
