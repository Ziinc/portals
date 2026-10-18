'use strict';

// Makes `require('portals-worker')` resolve to the bundled SDK on runtimes
// that ignore NODE_PATH. Portals.JavaScript preloads this file on Deno
// (`deno run --require=.../register.cjs`); Node.js and Bun use NODE_PATH.

const Module = require('module');
const path = require('path');

const sdk = path.join(__dirname, 'portals-worker', 'index.js');
const resolveFilename = Module._resolveFilename;

Module._resolveFilename = function resolvePortals(request, ...rest) {
  if (request === 'portals-worker') return sdk;
  return resolveFilename.call(this, request, ...rest);
};
