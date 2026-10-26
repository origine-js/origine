// `api.io`: the async runtime capability factory. Evaluated as an expression by src/api/glue.zig:
// `(native, util) => makeIoCap`. `makeIoCap(state)` returns a frozen `{ create, narrow }`.
// A runtime is created by the Rust native `native.io.create` (the ceiling is the embedder's
// `Config.runtime`); the glue only adds the narrowing the init asked for. A handle is frozen
// data `{ kind: 'io', id, backend }` plus `close()`; it is not transferable across scopes
// and `api.fs.requestAsync` takes it as `io`.
(native, { freeze, own, failure, ioHandles, closedIo, errors: { Unsupported, BadHandle } }) => {
  const BACKENDS = freeze(['auto', 'uring', 'kqueue', 'threaded']);

  // `state` = { parent, backends: string[] | undefined, max, live }: one record per narrowing.
  function makeIoCap(state) {
    const chain = [];
    for (let s = state; s !== null; s = s.parent) chain.push(s);

    function open(opts, backend) {
      const request = { backend };
      const entries = own(opts, 'entries');
      if (entries !== undefined) request.entries = entries;
      const made = native.io.create(request);
      let handle;
      let nextTimer = 0;
      // Every call returns the same promise, which settles when the runtime is really closed. The
      // handle is marked closed (new work is refused) as soon as the first close starts, but the
      // narrowing slots are only given back once it settles. Without `native.io.close` the call
      // rejects Unsupported and the handle stays open.
      let closing;
      const close = () => {
        if (closing !== undefined) return closing;
        if (native.io.close === undefined) return Promise.reject(failure(Unsupported));
        closedIo.add(handle);
        closing = (async () => {
          try {
            await native.io.close(made.id);
          } finally {
            for (const s of chain) s.live--;
          }
        })();
        return closing;
      };
      // Resolves once every flowing socket or server of this runtime has closed (immediately when
      // none is): `await io.run()` keeps the program alive for event-style handlers.
      const run = () => {
        if (closedIo.has(handle)) return Promise.reject(failure(BadHandle));
        return native.io.run === undefined ? Promise.reject(failure(Unsupported)) : native.io.run(made.id);
      };
      const now = () => {
        if (closedIo.has(handle)) throw failure(BadHandle);
        return native.io.now(made.id);
      };
      const timer = ms => {
        if (typeof ms !== 'number' || !Number.isFinite(ms) || ms < 0 || ms > 2147483647)
          throw new TypeError('milliseconds must be finite and between 0 and 2147483647');
        if (closedIo.has(handle)) throw failure(BadHandle);
        if (nextTimer > 0xffffffff) throw failure(Unsupported);
        const token = nextTimer++;
        const promise = native.io.sleep(made.id, token, ms);
        const cancel = () => (closedIo.has(handle) ? false : native.io.cancelTimer(made.id, token));
        return freeze({ promise, cancel });
      };
      const timerAt = deadline => {
        if (typeof deadline !== 'number' || !Number.isFinite(deadline) || deadline < 0)
          throw new TypeError('deadline must be a finite non-negative monotonic time');
        return timer(Math.max(0, deadline - now()));
      };
      const sleep = ms => timer(ms).promise;
      const sleepUntil = deadline => timerAt(deadline).promise;
      handle = freeze({ kind: 'io', id: made.id, backend: made.backend, close, run, now, timer, timerAt, sleep, sleepUntil });
      ioHandles.add(handle);
      for (const s of chain) s.live++;
      return handle;
    }

    return freeze({
      // Synchronous; throws a frozen `{ errno, name }` (InvalidInput for bad options, Unsupported
      // when the backend or the runtime count is not allowed or available).
      create(opts) {
        if (opts !== undefined && (opts === null || typeof opts !== 'object')) throw new TypeError('options must be an object');
        const backend = own(opts, 'backend');
        const entries = own(opts, 'entries');
        if (backend !== undefined && !BACKENDS.includes(backend)) throw new TypeError('unknown backend');
        if (entries !== undefined && !(Number.isSafeInteger(entries) && entries > 0))
          throw new TypeError('entries must be a positive integer');
        for (const s of chain) if (s.live >= s.max) throw failure(Unsupported);
        // The narrowest backend list wins; `auto` then means "the first allowed one that works".
        let allowed;
        for (const s of chain)
          if (s.backends !== undefined) allowed = allowed === undefined ? s.backends : allowed.filter(b => s.backends.includes(b));
        if (allowed === undefined) return open(opts, backend ?? 'auto');
        if (backend !== undefined && backend !== 'auto') {
          if (!allowed.includes(backend)) throw failure(Unsupported);
          return open(opts, backend);
        }
        let last = failure(Unsupported);
        for (const candidate of allowed) {
          try {
            return open(opts, candidate);
          } catch (e) {
            if (e === null || typeof e !== 'object' || e.errno !== Unsupported) throw e;
            last = e;
          }
        }
        throw last;
      },
      narrow(next) {
        const backends = own(next, 'backends');
        const max = own(next, 'maxRuntimes');
        if (backends !== undefined && (!Array.isArray(backends) || !backends.every(b => BACKENDS.includes(b) && b !== 'auto'))) {
          throw new TypeError('backends must be an array of uring, kqueue, threaded');
        }
        if (max !== undefined && (typeof max !== 'number' || !(max >= 0))) throw new TypeError('maxRuntimes must be a non-negative number');
        return makeIoCap({
          parent: state,
          backends: backends === undefined ? undefined : freeze([...backends]),
          max: max ?? Infinity,
          live: 0,
        });
      },
    });
  }

  return makeIoCap;
};
