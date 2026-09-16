#!/usr/bin/env ruby
# frozen_string_literal: true

# Same worker as `run_worker.rb`, over the framed stdio fallback transport.

here = File.expand_path(__dir__)
$LOAD_PATH.unshift(here)
$LOAD_PATH.unshift(File.expand_path('../../lib', here))

require 'portals'
require 'bench_worker'
require 'conformance_worker'

Portals::Worker.new(max_concurrency: 16, max_streams: 8, transport: :stdio).run
