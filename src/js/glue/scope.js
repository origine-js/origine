// `api.scope`: the scope capability factory. Evaluated as an expression by src/api/glue.zig:
// `(native, util) => makeScopeCap`. `makeScopeCap()` returns the frozen `{ create }`.
(native, { freeze, errno, take, failure, own, errors: { InvalidInput } }) => {
  // `{ ".ts": transformer, ... }` -> flat `[ext, transformer, ...]` for the native; undefined
  // when absent, null when malformed. Own data properties only. The native validates again
  // (extension syntax, count, duplicates, host-transformer brands): it is the trust anchor.
  const MAX_TRANSFORMERS = 64;
  function transformerList(map) {
    if (map === undefined) return undefined;
    if (map === null || typeof map !== 'object') return null;
    const keys = Object.keys(map);
    if (keys.length > MAX_TRANSFORMERS) return null;
    const flat = [];
    for (const ext of keys) {
      const transformer = own(map, ext);
      if (typeof transformer !== 'function') return null;
      flat.push(ext, transformer);
    }
    return freeze(flat);
  }

  const dispose = Symbol.dispose ?? Symbol.for('Symbol.dispose');

  function makeScopeCap() {
    function handle(id) {
      return freeze({
        // `using scope = await api.scope.create(...)`: closes, and never throws when already closed.
        [dispose]() {
          native.scope.close(id);
          take();
        },
        run() {
          const promise = native.scope.run(id);
          return errno[0] === 0 ? promise : Promise.reject(failure(take()));
        },
        close() {
          native.scope.close(id);
          if (errno[0] !== 0) throw failure(take());
        },
      });
    }
    return freeze({
      create(options) {
        const main = own(options, 'main');
        const map = own(options, 'importMap');
        const loader = own(options, 'loader');
        const preload = own(options, 'preload') ?? [];
        const flat = transformerList(own(options, 'transformers'));
        const origine = own(options, 'origineNamespace');
        if (
          typeof main !== 'string' ||
          (loader !== undefined && typeof loader !== 'function') ||
          (origine !== undefined && typeof origine !== 'boolean') ||
          !Array.isArray(preload) ||
          flat === null ||
          (flat !== undefined && loader === undefined)
        ) {
          return Promise.reject(failure(InvalidInput));
        }
        let mapJson;
        try {
          mapJson = map === undefined ? undefined : JSON.stringify(map);
        } catch {
          return Promise.reject(failure(InvalidInput));
        }
        // Every entry is `{ source, values }` (a function expression, called with `values`) or
        // `{ module, values }` (ES module source whose default export, if a function, is called
        // with `values`). Checked before the child exists so a bad entry creates nothing.
        for (let i = 0; i < preload.length; i++) {
          const entry = preload[i];
          const script = own(entry, 'source');
          const module = own(entry, 'module');
          if ((typeof script === 'string') === (typeof module === 'string')) return Promise.reject(failure(InvalidInput));
        }
        const id = native.scope.create(main, mapJson, loader, flat, origine === true);
        if (errno[0] !== 0) return Promise.reject(failure(take()));
        return (async () => {
          for (let i = 0; i < preload.length; i++) {
            const script = own(preload[i], 'source');
            const values = own(preload[i], 'values');
            try {
              if (typeof script === 'string') {
                native.scope.preload(id, script, 'preload:' + i, values);
                if (errno[0] !== 0) throw failure(take());
              } else {
                const done = native.scope.preloadModule(id, 'preload:' + i, own(preload[i], 'module'), values);
                if (errno[0] !== 0) throw failure(take());
                await done;
              }
            } catch (error) {
              native.scope.close(id);
              take();
              throw error;
            }
          }
          return handle(id);
        })();
      },
    });
  }

  return makeScopeCap;
};
