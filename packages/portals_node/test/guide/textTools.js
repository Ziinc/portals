'use strict';

const portals = require('portals-worker');

const wordCount = (text) => text.split(/\s+/).filter(Boolean).length;

const parseInteger = (text) => {
  const n = Number.parseInt(text, 10);
  if (Number.isNaN(n)) throw new TypeError(`not an integer: ${text}`); // becomes %Portals.Error{kind: :remote}
  return n;
};

const progress = async (steps) => {
  for (let step = 1; step <= steps; step += 1) {
    // Awaits MyApp.Progress.report/1 without blocking other calls.
    await portals.callback('Elixir.MyApp.Progress', 'report', [step]);
  }
  return steps;
};

const notify = (pid, text) => {
  portals.sendMessage(pid, text.toUpperCase()); // fire-and-forget
  return 'sent';
};

const upcaseStream = portals.streamHandler(async (stream) => {
  let count = 0;
  for await (const chunk of stream) { // ends when the BEAM half-closes its side
    await stream.send(chunk.toUpperCase()); // waits while the BEAM's credit is used up
    count += 1;
  }
  return count; // the stream's final result
});

module.exports = {
  word_count: wordCount,
  parse_int: parseInteger,
  progress,
  notify,
  upcase_stream: upcaseStream,
};
