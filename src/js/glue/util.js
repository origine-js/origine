import { ERRNO } from './errno.js';
import { of, fromDetail, resetDetail, moduleFailure, OrigineError } from './errors.js';

// Shared helpers for the glue modules. Nothing here touches the host: the realm's `native` object
// reaches a capability factory as an argument (index.js), so no module holds it ambiently.
//
// Error protocol: natives write a non-zero errno into element 0 of `native.errno`, a Uint32Array
// over native memory, and return a neutral value (undefined / 0). They clear it on entry.
export const errors = Object.freeze({ ...ERRNO.io, ...ERRNO.host });
// What a failed native or a refused request throws: an `IoError` or `HostError` instance.
export const failure = of;

// The errno cell of one `native` with the `ErrorDetail` next to it (neither is ever reassigned), and
// the read-and-clear every native call is followed by. `takeError` is the error the call left, or
// undefined; `take` discards it.
export function errnoCell(native) {
  const { errno, detail } = native;
  const take = () => {
    const code = errno[0];
    errno[0] = 0;
    if (code !== 0) resetDetail(detail);
    return code;
  };
  const takeError = () => {
    const code = errno[0];
    if (code === 0) return undefined;
    errno[0] = 0;
    const error = fromDetail(code, detail);
    resetDetail(detail);
    return error;
  };
  return Object.freeze({ errno, detail, take, takeError });
}
// Parts one factory publishes for another (the graph glue for the context glue). Glue modules are
// evaluated once per realm, so these are per-realm state.
export const shared = {};
// Io handles made by this realm's `api.io` and the ones already closed; `api.fs.requestAsync`
// accepts only live members of the first set (the Rust natives validate the id again).
export const ioHandles = new WeakSet();
export const closedIo = new WeakSet();
// Io handle -> what must run when it closes (a closed runtime dispatches nothing more, so this
// is how state kept in JS learns of it). Entries take the `Canceled` failure.
export const ioClosers = new WeakMap();
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

// The Rust natives reject with an `Error` carrying `errno`, `name` and the `ErrorDetail` fields
// (`subject`, `os`): callers get the shared error class instance, with those fields, instead.
const hostError = e => (typeof e?.errno === 'number' && !(e instanceof OrigineError) ? fromDetail(e.errno, e) : e);
export const settled = promise =>
  promise.then(undefined, e => {
    throw hostError(e);
  });

// A promise of a module import, evaluation or preload: its rejection becomes a `ModuleError`.
export const moduleSettled = promise =>
  promise.then(undefined, e => {
    throw moduleFailure(e);
  });

// `ops` with every promise one of its operations returns passed through `settled`, and every error one throws
// converted the same way.
export const settling = ops =>
  Object.fromEntries(
    Object.entries(ops).map(([name, op]) => [
      name,
      typeof op !== 'function' ? op : (...args) => {
        let result;
        try {
          result = op(...args);
        } catch (e) {
          throw hostError(e);
        }
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
