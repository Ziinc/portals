'use strict';

const portals = require('portals-worker');

const names = { node: 'Node.js', bun: 'Bun', deno: 'Deno', quickjs: 'QuickJS' };

// The same file runs on every runtime; portals.runtime() says which one.
const hello = (name) => {
  const { name: runtime, version } = portals.runtime();
  return `Hello, ${name}! I'm JavaScript on ${names[runtime]} ${version}.`;
};

module.exports = { hello };
