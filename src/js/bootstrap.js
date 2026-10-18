// Intrinsic inventory: V8 15.2.124.1. Executed only in a pristine context.
// This is a hardening bootstrap, not a general JavaScript compartment library.
// Borrows the host-supplied intrinsic array through initialization; retains its
// object identities in a private WeakSet for the lifetime of the returned helpers.
((intrinsicObjects, unsupportedObjects) => {
  'use strict';
  const { freeze, getPrototypeOf, getOwnPropertyDescriptor } = Object;
  const ownKeys = Reflect.ownKeys;
  const intrinsics = new WeakSet(intrinsicObjects);
  const unsupported = new WeakSet(unsupportedObjects);
  for (const name of ['WeakRef', 'FinalizationRegistry']) {
    if (typeof globalThis[name] === 'function') unsupported.add(globalThis[name].prototype);
  }
  // Kept in a host persistent handle; never installed in the guest global.
  // Borrows root and synchronous validator through return; freezes supported
  // objects in place and returns the identical root. Validation failure freezes
  // nothing; freezing failure can leave a partially frozen caller-owned graph.
  // Retains no new graph after return; the closure retains intrinsic policy.
  function harden(root, supported) {
    const seen = new WeakSet();
    const pending = [];
    // Borrows value through this call; records references until harden returns.
    // No getter bodies run. Validation errors propagate before any freezing.
    function visit(value) {
      if (value === null || (typeof value !== 'object' && typeof value !== 'function')) return;
      // Native validation must precede even WeakSet/descriptor/prototype operations.
      if (!supported(value)) throw new TypeError('Unsupported export object');
      if (unsupported.has(value)) throw new TypeError('Unsupported export prototype');
      if (intrinsics.has(value) || seen.has(value)) return;
      seen.add(value);
      pending.push(value);
      visit(getPrototypeOf(value));
      for (const key of ownKeys(value)) {
        const d = getOwnPropertyDescriptor(value, key);
        if ('value' in d) visit(d.value);
        else { visit(d.get); visit(d.set); }
      }
    }
    visit(root);
    for (const value of pending) freeze(value)
    return root;
  }
  // Borrows value through the callback; retains no resources from the argument.
  const isUnsupported = value => unsupported.has(value);
  return [harden, isUnsupported];
})
