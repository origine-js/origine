// Guest-side glue for the `api` object. Evaluated once per scope by src/api/glue.zig with
// the native function tables as `native`; returns the (unfrozen) api object, which the host
// then deep-freezes. Natives are the trust anchor: they validate every handle, path and
// grant. The glue only shapes the surface (sync/async variants, narrowing wrappers, option
// parsing) and never holds authority itself.
//
// Parts: util.js (shared helpers and the errno protocol), fs.js, env.js, scope.js (one
// capability factory each). glue.zig splices them in as `util`, `fs`, `env` and `scope`.
(native, util, fs, env, scope) => {
  'use strict';
  const { freeze } = util;
  return freeze({
    fs: fs(native, util)({ root: undefined, write: true, async: true, sync: true }),
    env: env(native, util)(null),
    scope: scope(native, util)({ remaining: Infinity }),
  });
}
