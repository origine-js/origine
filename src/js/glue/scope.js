// `api.scope`: the scope capability factory. Evaluated as an expression by src/api/glue.zig:
// `(native, util) => makeScopeCap`. `makeScopeCap(state)` tracks how many more scopes may be created.
(native, { freeze, errno, take, failure, own, errors: { InvalidPath, Unsupported } }) => {
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

  function makeScopeCap(state) {
    function handle(id) {
      return freeze({
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
        if (
          typeof main !== 'string' ||
          (loader !== undefined && typeof loader !== 'function') ||
          !Array.isArray(preload) ||
          flat === null ||
          (flat !== undefined && loader === undefined)
        ) {
          return Promise.reject(failure(InvalidPath));
        }
        if (state.remaining <= 0) return Promise.reject(failure(Unsupported));
        let mapJson;
        try {
          mapJson = map === undefined ? undefined : JSON.stringify(map);
        } catch {
          return Promise.reject(failure(InvalidPath));
        }
        const id = native.scope.create(main, mapJson, loader, flat);
        if (errno[0] !== 0) return Promise.reject(failure(take()));
        state.remaining--;
        for (let i = 0; i < preload.length; i++) {
          const source = own(preload[i], 'source');
          if (typeof source !== 'string') {
            native.scope.close(id);
            take();
            return Promise.reject(failure(InvalidPath));
          }
          native.scope.preload(id, source, 'preload:' + i, own(preload[i], 'values'));
          if (errno[0] !== 0) {
            const code = take();
            native.scope.close(id);
            take();
            return Promise.reject(failure(code));
          }
        }
        return Promise.resolve(handle(id));
      },
      narrow(next) {
        const count = own(next, 'count');
        if (count !== undefined && (typeof count !== 'number' || !(count >= 0))) throw new TypeError('count must be a non-negative number');
        return makeScopeCap({ remaining: Math.min(state.remaining, count ?? Infinity) });
      },
    });
  }

  return makeScopeCap;
};
