// `api.io`: the async runtime capability factory. An ES module factory used by index.js: its default export takes the
// per-realm native and returns `makeIoCap(state)`, which returns a frozen `{ create, narrow }`.
// A runtime is created by the Rust native `native.io.create` (the ceiling is the embedder's `Config.runtime`); the
// glue only adds the narrowing the init asked for. The result is an `Io`, a class defined in Rust
// (rust/crates/origine_api/src/io.rs) with its tables `io.timer`, `io.tcp` and `io.udp`; no runtime id reaches the
// guest. `api.fs.requestAsync` takes it as `io`.
import { freeze, own, failure, shared, errors, hostError } from './util.js';
const { Unsupported } = errors;
export default native => {
  const BACKENDS = freeze(['auto', 'uring', 'kqueue', 'threaded']);
  let installed = false;
  // The classes, installed when the capability is bound (index.js `late`): `[Symbol.asyncDispose]` is the only JS
  // member (`await using io = api.io.create()` closes the runtime on scope exit).
  const install = () => {
    if (installed) return;
    installed = true;
    shared.Io = native.io.Io(hostError, {
      [Symbol.asyncDispose]() {
        return this.close();
      },
    });
    native.io.IoTimer(hostError);
    native.io.Timer(hostError);
    native.io.IoTcp(hostError);
    native.io.IoUdp(hostError);
    // For `api.fs.requestAsync` and `api.dns`: the runtime number of a live `Io` (`BadHandle` otherwise).
    shared.ioRuntime = io => native.io.runtime(io);
  };

  // `state` = { parent, backends: string[] | undefined, max, live }: one record per narrowing.
  function makeIoCap(state) {
    install();
    const chain = [];
    for (let s = state; s !== null; s = s.parent) chain.push(s);

    function open(opts, backend) {
      const request = { backend };
      const entries = own(opts, 'entries');
      if (entries !== undefined) request.entries = entries;
      // Called when `close()` starts: the narrowing slots are given back once it settles, and the async fs grants
      // opened on the runtime stop being an authority.
      const closing = (promise, runtime) => {
        shared.asyncFsClosed?.(runtime);
        const release = () => {
          for (const s of chain) s.live--;
        };
        promise.then(release, release);
      };
      const io = native.io.create(request, closing);
      for (const s of chain) s.live++;
      return io;
    }

    return freeze({
      // Synchronous; throws an `OrigineError` subclass instance (Unsupported when the backend or the runtime count is
      // not allowed or available) or a TypeError for bad options.
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
