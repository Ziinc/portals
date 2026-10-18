'use strict';

// Portals starts this script and appends the socket path as the last argument.
const { Worker } = require('portals-worker');

new Worker({
  maxConcurrency: 8,
  maxStreams: 4,
  modules: { text_tools: require('./textTools') },
})
  .run()
  .catch((err) => {
    process.stderr.write(`${err.stack}\n`);
    process.exit(1);
  });
