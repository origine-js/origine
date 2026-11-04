// `api.io`: the async runtime capability factory. An ES module factory used by index.js: its default export takes the
// per-realm native and returns the builder of the frozen `{ create }`.
// A runtime is created by the Rust native `native.io.create` (the ceiling is the embedder's `Config.runtime`; there
// is no narrowing below it). The result is an `Io`, a class defined in Rust (rust/crates/origine_api/src/io.rs) with
// its tables `io.timer`, `io.tcp` and `io.udp`; no runtime id reaches the guest. `api.fs.requestAsync` takes it as
// `io`.
import { freeze, own, shared, hostError } from './util.js';
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
    // Told when a runtime of this realm starts closing: the async fs grants opened on it stop being an authority.
    native.io.link(runtime => shared.asyncFsClosed?.(runtime));
  };

  return () => {
    install();
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
        const request = { backend: backend ?? 'auto' };
        if (entries !== undefined) request.entries = entries;
        return native.io.create(request);
      },
    });
  };
};
