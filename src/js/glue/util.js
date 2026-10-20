// Shared helpers for the glue factories. Evaluated as an expression by src/api/glue.zig:
// `(native) => util`.
//
// Error protocol: natives write a non-zero errno into element 0 of `native.errno`,
// a Uint32Array over native memory fetched once per scope, and return a neutral
// value (undefined / 0). They clear it on entry.
(native) => {
  const { freeze, getOwnPropertyDescriptor } = Object;
  const errno = native.errno;
  // Reads and clears the shared errno cell.
  const take = () => { const code = errno[0]; errno[0] = 0; return code; };
  // `native.errors` is generated from the Zig `Errno` enum: { FileNotFound: 1, ... }.
  const errors = native.errors;
  const names = freeze(Object.fromEntries(Object.entries(errors).map(([name, code]) => [code, name])));
  const failure = code => freeze({ errno: code, name: names[code] ?? 'Unexpected' });

  // Own data properties only: no getters, no prototype lookups.
  const own = (object, key) => {
    if (object === null || typeof object !== 'object') return undefined;
    const descriptor = getOwnPropertyDescriptor(object, key);
    return descriptor !== undefined && 'value' in descriptor ? descriptor.value : undefined;
  };
  const joinPath = (a, b) => (a === undefined || a === '') ? b : (b === undefined || b === '') ? a : a + '/' + b;

  return { freeze, errno, take, errors, failure, own, joinPath };
}
