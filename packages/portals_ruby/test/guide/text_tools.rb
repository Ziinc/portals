# frozen_string_literal: true

require 'portals'

module TextTools
  extend Portals::StreamHandlers
  module_function

  def word_count(text)
    text.split.length
  end

  def parse_int(text)
    Integer(text) # an ArgumentError becomes %Portals.Error{kind: :remote}
  end

  def progress(steps)
    (1..steps).each do |step|
      # Blocks this handler's thread until MyApp.Progress.report/1 returns.
      Portals.callback('Elixir.MyApp.Progress', 'report', [step])
    end
    steps
  end

  def notify(pid, text)
    Portals.send_message(pid, text.upcase) # fire-and-forget
    'sent'
  end

  stream_handler def upcase_stream(stream)
    count = 0
    while (chunk = stream.recv) # nil once the BEAM half-closes its side
      stream.send(chunk.upcase) # blocks while the BEAM's credit is used up
      count += 1
    end
    count # the stream's final result
  end
end
