'use strict';

// Structured remote-error mapping (FR-4). Every uncaught error thrown by a
// called function becomes an `ERROR` frame carrying language, error type,
// message, and a normalized, bounded stack — never a raw serialized object.
// The wire shape matches `%Portals.Error{}`:
// `kind`/`message`/`details`/`remote`/`stacktrace`.

const MAX_STACK_FRAMES = 64;
const MAX_MESSAGE_SIZE = 4096;

function buildErrorMap(error) {
  const isError = error instanceof Error;
  let message = isError ? String(error.message) : String(error);
  if (Buffer.byteLength(message, 'utf8') > MAX_MESSAGE_SIZE) {
    message = message.slice(0, MAX_MESSAGE_SIZE);
  }

  const stack = isError && typeof error.stack === 'string' ? error.stack.split('\n') : [];

  return {
    kind: 'remote',
    message: message || (isError ? error.constructor.name : 'error'),
    details: {},
    remote: {
      language: 'javascript',
      exception_type: isError ? error.constructor.name : typeof error,
    },
    stacktrace: stack.slice(-MAX_STACK_FRAMES).map((line) => line.trim()),
  };
}

// A terminal `overload` error, used when the worker is at its advertised
// stream or concurrency capacity.
function overloadErrorMap(message) {
  return { kind: 'overload', message, details: {}, remote: { language: 'javascript' } };
}

function protocolErrorMap(message) {
  return { kind: 'protocol', message, details: {}, remote: { language: 'javascript' } };
}

module.exports = { buildErrorMap, overloadErrorMap, protocolErrorMap, MAX_STACK_FRAMES, MAX_MESSAGE_SIZE };
