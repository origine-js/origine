// Builds a host-independent API template. Snapshots prepare every JS capability here;
// restored getters bind native authority only on first access. Without a snapshot,
// native.load also supplies each capability factory from its separate code cache.
(native, util) => {
  'use strict';
  const { freeze, freezeMethods } = util;
  const capabilities = Object.create(null);
  const bound = Object.create(null);
  const options = {
    fs: { root: undefined, write: true, async: true, sync: true },
    host: undefined,
    graph: undefined,
    context: undefined,
    io: { parent: null, backends: undefined, max: Infinity, live: 0 },
    net: undefined,
  };
  const prepare = (name, factory) => {
    capabilities[name] = freezeMethods(factory(native, util)(options[name]));
  };
  const full = {};
  const basic = {};
  // `context` is built on the parts `graph` publishes, so binding it binds `graph` first.
  const needs = { context: 'graph' };
  const access = name => {
    if (needs[name] !== undefined) access(needs[name]);
    if (!bound[name]) {
      // Accessing a capability must preserve a pending synchronous fs error.
      const previous = util.errno[0];
      try {
        const factory = native.load(name, native, capabilities[name] === undefined);
        const code = util.take();
        if (code !== 0) throw util.failure(code);
        if (factory !== undefined) prepare(name, factory);
        bound[name] = true;
      } finally {
        util.errno[0] = previous;
      }
    }
    return capabilities[name];
  };
  for (const name of ['fs', 'host', 'graph', 'context', 'io', 'net']) {
    const get = freeze(() => access(name));
    const descriptor = { get, enumerable: true, configurable: false };
    Object.defineProperty(full, name, descriptor);
    if (name !== 'io' && name !== 'net') Object.defineProperty(basic, name, descriptor);
  }
  // Private context embedder data holds this bundle; guest code receives only an API.
  return [freeze(full), freeze(basic), native, util.errno, prepare];
};
