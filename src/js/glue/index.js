import * as util from './util.js';
import { OrigineError, IoError, HostError, ImportError } from './errors.js';
import fs from './fs.js';
import host from './host.js';
import graph from './graph.js';
import context from './context.js';
import isolate from './isolate.js';
import io from './io.js';
import net from './net.js';
const factories = {
  fs,
  host,
  graph,
  context,
  isolate,
  io,
  net,
};

// Builds a host-independent API template for one realm from its `native` object (the errno cell
// to start with; `native.bind` arrives at install). Snapshots prepare every JS capability here;
// the getters bind native authority only on first access. Returns the bundle the host keeps in
// private context embedder data: [full api, basic api, native, errno cell, initial, errors, records].
export function create(native) {
  const cell = util.errnoCell(native);
  const { freeze, freezeMethods } = util;
  const capabilities = Object.create(null);
  const bound = Object.create(null);
  const options = {
    fs: { root: undefined, write: true, async: true, sync: true },
    host: undefined,
    graph: undefined,
    context: undefined,
    isolate: undefined,
    io: { parent: null, backends: undefined, max: Infinity, live: 0 },
    net: undefined,
  };
  const full = {};
  const basic = {};
  // `context` is built on the parts `graph` publishes, so binding it binds `graph` first.
  const needs = { context: 'graph', isolate: 'host' };
  const access = name => {
    if (needs[name] !== undefined) access(needs[name]);
    if (!bound[name]) {
      // Accessing a capability must preserve a pending synchronous fs error.
      const previous = cell.errno[0];
      try {
        native.bind(name, native);
        const code = cell.take();
        if (code !== 0) throw util.failure(code);
        bound[name] = true;
      } finally {
        cell.errno[0] = previous;
      }
    }
    return capabilities[name];
  };
  for (const [name, factory] of Object.entries(factories)) {
    capabilities[name] = freezeMethods(factory(native, cell)(options[name]));
    const descriptor = { get: freeze(() => access(name)), enumerable: true, configurable: false };
    Object.defineProperty(full, name, descriptor);
    if (name !== 'io' && name !== 'net' && name !== 'isolate') Object.defineProperty(basic, name, descriptor);
  }
  // The second argument of `main`: what the creating isolate passed to `api.isolate.create`.
  const initial = () => {
    access('isolate');
    return util.shared.initial();
  };
  return [freeze(full), freeze(basic), native, cell.errno, initial, freeze({ OrigineError, IoError, HostError, ImportError }), util.records];
}
