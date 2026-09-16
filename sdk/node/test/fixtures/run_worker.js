#!/usr/bin/env node
'use strict';

// Entry point launched by Portals as the direct worker process (the socket
// path is appended as the final CLI argument by `Portals.Connection`).
// Registers the fixture modules under the names the BEAM uses in `CALL`,
// then runs the worker loop.

const { Worker } = require('../..');

const worker = new Worker({
  maxConcurrency: Number(process.env.PORTALS_MAX_CONCURRENCY ?? 64),
  maxStreams: Number(process.env.PORTALS_MAX_STREAMS ?? 8),
  protocolVersion: Number(process.env.PORTALS_PROTOCOL_VERSION ?? 1),
  transport: process.env.PORTALS_TRANSPORT ?? 'unix',
  modules: {
    bench_worker: require('./bench_worker'),
    conformance_worker: require('./conformance_worker'),
  },
  modulePaths: [__dirname],
});

worker.run().catch((err) => {
  process.stderr.write(`portals worker: ${err.stack || err}\n`);
  process.exit(1);
});
