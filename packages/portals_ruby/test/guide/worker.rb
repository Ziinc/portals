# frozen_string_literal: true

# Portals starts this script and appends the socket path as the last argument.
require 'portals'
require_relative 'text_tools'

Portals::Worker.new(
  max_concurrency: 8,
  max_streams: 4,
  modules: { 'text_tools' => TextTools }
).run
