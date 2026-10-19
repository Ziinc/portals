'use strict';

// Which JavaScript runtime this worker is running on. The same SDK runs on
// Node.js, Bun, Deno (through its Node compatibility layer) and QuickJS
// (through quickjs/host.mjs, which provides the Node APIs the SDK uses).

function runtime() {
  /* global Bun, Deno */
  if (typeof Bun !== 'undefined') return { name: 'bun', version: Bun.version };
  if (typeof Deno !== 'undefined') return { name: 'deno', version: Deno.version.deno };
  if (process.versions && process.versions.quickjs) {
    return { name: 'quickjs', version: process.versions.quickjs };
  }
  return { name: 'node', version: process.versions.node };
}

module.exports = { runtime };
