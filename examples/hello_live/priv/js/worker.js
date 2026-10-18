'use strict';

const { Worker } = require('portals-worker');

new Worker({ modules: { greeter: require('./greeter') } }).run();
