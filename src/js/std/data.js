// `origine:@std/data`: hand data to another realm without sharing the realm. `snapshot` copies plain data and
// `deepFreeze` freezes a graph of it in place; both are separate calls, applied to any object, so nothing in
// the graph API copies or freezes on a caller's behalf. The host hands this module two natives through
// `import.meta.native` (captured here, never exported).
import { IoError } from 'origine:@std/errors';
const { isProxy, deepFreeze: freezeNative } = import.meta.native;

const unsupported = message => new IoError(IoError.Unsupported, message);
const invalid = message => new IoError(IoError.InvalidInput, message);

/// Freezes `value` and everything it reaches **in place** and returns it: own data properties and the
/// prototype chain and a class's statics, so freezing an exported class also freezes the prototypes involved. Anything else the exporter keeps mutating
/// through it will throw (strict mode) or silently fail (sloppy): freezing a graph the owner still writes to is the
/// caller's responsibility. A primitive is returned as it is. A `Map`, a `Set`, a typed array, an `ArrayBuffer`, a
/// promise or a `Proxy` anywhere in the graph is `Unsupported` (the graph may be partly frozen by then). An accessor
/// property is frozen as a property, but its getter still runs and may return anything: freezing cannot make that
/// immutable. It is `Object.freeze`, transitively; that is why it is not called `freeze`. It is not a security boundary
/// by itself: a frozen function still has `fn.constructor`; string-to-code is closed by `security.codeGeneration`.
export function deepFreeze(value) {
  if (value === null || (typeof value !== 'object' && typeof value !== 'function')) return value;
  if (!freezeNative(value))
    throw unsupported(
      'deepFreeze: the graph holds a Map, a Set, a typed array, an ArrayBuffer, a promise or a Proxy, which cannot be frozen',
    );
  return value;
}

const isPlainPrototype = prototype => prototype === null || Object.getPrototypeOf(prototype) === null;

/// A copy of plain data: primitives (a `bigint` and a `symbol` included, as they are), arrays and objects whose
/// prototype is a realm's `Object.prototype` or null, with cycles and shared references kept. The copy is made
/// in this realm and belongs to the caller; the source is not touched. Absent `deepFreeze` means `false`; with
/// `deepFreeze: true` the copy is also deeply frozen (`deepFreeze`). A function or class, an accessor property, a
/// `Map`, a `Set`, a typed array, a promise, a `Proxy`, a `Date` or any object with another prototype is
/// `Unsupported`, naming where it is: nothing is shared silently, since a shared object would leak its realm.
/// A symbol-keyed property is skipped, as `Object.keys` skips it.
export function snapshot(value, options) {
  if (options !== undefined && (options === null || typeof options !== 'object')) throw invalid('snapshot: options must be an object');
  const frozen = options?.deepFreeze;
  if (frozen !== undefined && typeof frozen !== 'boolean') throw invalid('snapshot: deepFreeze must be a boolean');
  const copy = copyOf(value, '$', new Map());
  return frozen === true ? deepFreeze(copy) : copy;
}

function copyOf(value, path, seen) {
  if (value === null || (typeof value !== 'object' && typeof value !== 'function')) return value;
  if (typeof value === 'function')
    throw unsupported(`snapshot: ${path} is a function; a function cannot be copied, pass it to Import.exports as it is`);
  const known = seen.get(value);
  if (known !== undefined) return known;
  if (isProxy(value)) throw unsupported(`snapshot: ${path} is a Proxy`);
  const copyProperties = (from, to) => {
    for (const key of Object.keys(from)) {
      const descriptor = Object.getOwnPropertyDescriptor(from, key);
      if (!('value' in descriptor)) throw unsupported(`snapshot: ${path}.${key} is an accessor`);
      Object.defineProperty(to, key, {
        value: copyOf(descriptor.value, `${path}.${key}`, seen),
        enumerable: true,
        writable: true,
        configurable: true,
      });
    }
    return to;
  };
  if (Array.isArray(value)) {
    const copy = [];
    seen.set(value, copy);
    return copyProperties(value, copy);
  }
  const prototype = Object.getPrototypeOf(value);
  // A Map, Set, typed array, promise or Date has its own prototype, so this refuses them too.
  if (!isPlainPrototype(prototype))
    throw unsupported(`snapshot: ${path} is not plain data (it has a prototype other than Object.prototype)`);
  const copy = prototype === null ? Object.create(null) : {};
  seen.set(value, copy);
  return copyProperties(value, copy);
}
