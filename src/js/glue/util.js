import { ERRNO } from './errno.js';
import { of } from './errors.js';

// Shared helpers for the glue modules. Nothing here touches the host: the realm's `native` object
// reaches a capability factory as an argument (index.js), so no module holds it ambiently.
//
// Error protocol: natives write a non-zero errno into element 0 of `native.errno`, a Uint32Array
// over native memory, and return a neutral value (undefined / 0). They clear it on entry.
export const errors = Object.freeze({ ...ERRNO.io, ...ERRNO.host });
// What a failed native or a refused request throws: an `IoError` or `HostError` instance.
export const failure = of;

// The errno cell of one `native`, and the read-and-clear every native call is followed by.
export function errnoCell(native) {
  const errno = native.errno;
  const take = () => {
    const code = errno[0];
    errno[0] = 0;
    return code;
  };
  return Object.freeze({ errno, take });
}
// Parts one factory publishes for another (the graph glue for the context glue). Glue modules are
// evaluated once per realm, so these are per-realm state.
export const shared = {};
// Io handles made by this realm's `api.io` and the ones already closed; `api.fs.requestAsync`
// accepts only live members of the first set (the Rust natives validate the id again).
export const ioHandles = new WeakSet();
export const closedIo = new WeakSet();
export const freeze = Object.freeze;
// Freezes what it is given: a class (and its prototype) from its own `static {}` block, or an
// instance from its constructor. Returns the first argument.
export function seal(...targets) {
  for (const target of targets) {
    if (typeof target === 'function') Object.freeze(target.prototype);
    Object.freeze(target);
  }
  return targets[0];
}

export function freezeMethods(object) {
  for (const key of Reflect.ownKeys(object)) {
    const descriptor = Object.getOwnPropertyDescriptor(object, key);
    if (typeof descriptor.value === 'function') freeze(descriptor.value);
    if (descriptor.get !== undefined) freeze(descriptor.get);
    if (descriptor.set !== undefined) freeze(descriptor.set);
  }
  return freeze(object);
}

// The Rust natives reject with a plain `{ errno, name }`: callers get the error instance instead.
export const settled = promise =>
  promise.then(undefined, e => {
    throw typeof e?.errno === 'number' ? failure(e.errno) : e;
  });

// `ops` with every promise one of its operations returns passed through `settled`.
export const settling = ops =>
  Object.fromEntries(
    Object.entries(ops).map(([name, op]) => [
      name,
      typeof op !== 'function' ? op : (...args) => {
        const result = op(...args);
        return result instanceof Promise ? settled(result) : result;
      },
    ]),
  );

// Own data properties only: no getters, no prototype lookups.
export function own(object, key) {
  if (object === null || typeof object !== 'object') return undefined;
  const descriptor = Object.getOwnPropertyDescriptor(object, key);
  return descriptor !== undefined && 'value' in descriptor ? descriptor.value : undefined;
}

export const joinPath = (a, b) => (a === undefined || a === '' ? b : b === undefined || b === '' ? a : a + '/' + b);

// Adds `members` to `target` as frozen own properties and freezes it: the host built the object (a
// grant), the glue only gives it its operations. Defines properties, so no setter on a prototype runs.
export function completed(target, members) {
  for (const key of Reflect.ownKeys(members)) {
    Object.defineProperty(target, key, { value: members[key], enumerable: true, writable: false, configurable: false });
  }
  return freeze(target);
}
