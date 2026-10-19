# frozen_string_literal: true

require 'portals'
require_relative 'greeter'

Portals::Worker.new(modules: { 'greeter' => Greeter }).run
