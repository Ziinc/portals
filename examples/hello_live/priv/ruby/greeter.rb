# frozen_string_literal: true

module Greeter
  module_function

  def hello(name)
    "Hello, #{name}! I'm Ruby #{RUBY_VERSION}."
  end
end
