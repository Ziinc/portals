#!/usr/bin/env node
'use strict';

// Same worker as `run_worker.js`, over the framed stdio fallback transport.

const { Worker } = require('../..');

new Worker({
  maxConcurrency: 16,
  maxStreams: 8,
  transport: 'stdio',
  modules: {
    bench_worker: require('./bench_worker'),
    conformance_worker: require('./conformance_worker'),
  },
  modulePaths: [__dirname],
}).run().catch((err) => {
  process.stderr.write(`portals worker: ${err.stack || err}\n`);
  process.exit(1);
});
