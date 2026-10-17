// Guest-side glue for the `api` object. Evaluated once per scope by api.zig with
// the native function tables as `native`; returns the (unfrozen) api object, which
// the host then deep-freezes. Natives are the trust anchor: they validate every
// handle, path and grant. This glue only shapes the surface (sync/async variants,
// narrowing wrappers, option parsing) and never holds authority itself.
//
// Error protocol: natives write a non-zero errno into element 0 of the Uint32Array
// passed as their first argument and return a neutral value (undefined / 0).
((native) => {
  'use strict';
  const { freeze, getOwnPropertyDescriptor } = Object;
  const NAMES = freeze({ 1: 'FileNotFound', 2: 'AccessDenied', 3: 'NotDir', 4: 'IsDir', 5: 'PathAlreadyExists', 6: 'BadHandle', 7: 'StaleHandle', 8: 'InvalidPath', 9: 'NoSpaceLeft', 10: 'Unsupported', 11: 'FileTooBig', 255: 'Unexpected' });
  const InvalidPath = 8;
  const Unsupported = 10;
  const failure = code => freeze({ errno: code, name: NAMES[code] ?? 'Unexpected' });

  // Own data properties only: no getters, no prototype lookups.
  const own = (object, key) => {
    if (object === null || typeof object !== 'object') return undefined;
    const descriptor = getOwnPropertyDescriptor(object, key);
    return descriptor !== undefined && 'value' in descriptor ? descriptor.value : undefined;
  };
  const joinPath = (a, b) => (a === undefined || a === '') ? b : (b === undefined || b === '') ? a : a + '/' + b;

  // ---- fs ---------------------------------------------------------------

  const OPEN_WRITE = 1, OPEN_CREATE = 2, OPEN_TRUNCATE = 4, OPEN_EXCLUSIVE = 8;
  function openBits(flags) {
    const mode = own(flags, 'mode') ?? 'read';
    let bits = 0;
    if (mode === 'write' || mode === 'readwrite') bits |= OPEN_WRITE;
    else if (mode !== 'read') return -1;
    if (own(flags, 'create') === true) bits |= OPEN_CREATE;
    if (own(flags, 'truncate') === true) bits |= OPEN_TRUNCATE;
    if (own(flags, 'exclusive') === true) bits |= OPEN_EXCLUSIVE;
    return bits;
  }

  function makeFs(ops, errno) {
    const fsId = ops.id;
    const bad = () => { errno[0] = InvalidPath; };
    const dirArgs = dir => (dir !== null && typeof dir === 'object' && dir.kind === 'dir' && typeof dir.id === 'number' && typeof dir.fs === 'number') ? dir : null;
    const fileArgs = file => (file !== null && typeof file === 'object' && file.kind === 'file' && typeof file.id === 'number' && typeof file.fs === 'number') ? file : null;
    const raw = {
      dirOpenFile(dir, path, flags) {
        const d = dirArgs(dir), bits = openBits(flags);
        if (d === null || typeof path !== 'string' || bits < 0) return bad();
        const id = ops.openFile(errno, d.fs, d.id, path, bits);
        return errno[0] === 0 ? freeze({ kind: 'file', fs: fsId, id }) : undefined;
      },
      dirOpenDir(dir, path) {
        const d = dirArgs(dir);
        if (d === null || typeof path !== 'string') return bad();
        const id = ops.openDir(errno, d.fs, d.id, path);
        return errno[0] === 0 ? freeze({ kind: 'dir', fs: fsId, id }) : undefined;
      },
      dirClose(dir) {
        const d = dirArgs(dir);
        if (d === null) return void bad();
        ops.closeDir(errno, d.fs, d.id);
      },
      dirStat(dir, path) {
        const d = dirArgs(dir);
        if (d === null || typeof path !== 'string') return bad();
        const out = ops.stat(errno, d.fs, d.id, path);
        return errno[0] === 0 ? freeze({ kind: out[0], size: out[1] }) : undefined;
      },
      dirCreateDir(dir, path) {
        const d = dirArgs(dir);
        if (d === null || typeof path !== 'string') return void bad();
        ops.createDir(errno, d.fs, d.id, path);
      },
      dirDeleteFile(dir, path) {
        const d = dirArgs(dir);
        if (d === null || typeof path !== 'string') return void bad();
        ops.deleteFile(errno, d.fs, d.id, path);
      },
      dirRead(dir) {
        const d = dirArgs(dir);
        if (d === null) return bad();
        const flat = ops.readDir(errno, d.fs, d.id);
        if (errno[0] !== 0) return undefined;
        const entries = [];
        for (let i = 0; i < flat.length; i += 2) entries.push(freeze({ name: flat[i], kind: flat[i + 1] }));
        return freeze(entries);
      },
      fileReadAll(file, options) {
        const f = fileArgs(file);
        if (f === null) return bad();
        const limit = own(options, 'limit') ?? Infinity;
        if (typeof limit !== 'number' || !(limit >= 0)) return bad();
        return ops.readAll(errno, f.fs, f.id, limit);
      },
      fileWriteAll(file, bytes) {
        const f = fileArgs(file);
        if (f === null || !(bytes instanceof Uint8Array)) return void bad();
        ops.writeAll(errno, f.fs, f.id, bytes);
      },
      fileClose(file) {
        const f = fileArgs(file);
        if (f === null) return void bad();
        ops.close(errno, f.fs, f.id);
      },
    };
    // Async variant: same names, promise-returning. Draft-1 runs the operation
    // inline on the isolate thread and settles immediately; a host work queue
    // replaces this later without changing the surface.
    const asyncOps = {};
    for (const name of Object.keys(raw)) {
      const op = raw[name];
      asyncOps[name] = (...args) => {
        errno[0] = 0;
        let value;
        try { value = op(...args); } catch (e) { return Promise.reject(e); }
        const code = errno[0];
        if (code !== 0) { errno[0] = 0; return Promise.reject(failure(code)); }
        return Promise.resolve(value);
      };
    }
    return { raw, asyncOps };
  }

  function makeFsCap(spec) {
    return freeze({
      request(hint) {
        const errno = new Uint32Array(1);
        let root = own(hint, 'root');
        if (root !== undefined && typeof root !== 'string') return Promise.reject(failure(InvalidPath));
        root = joinPath(spec.root, root);
        const write = own(hint, 'write') === true && spec.write;
        const ops = native.fsRequest(errno, root, write);
        if (errno[0] !== 0) return Promise.reject(failure(errno[0]));
        const sync = own(hint, 'sync') === true && spec.sync && ops.sync === true;
        const { raw, asyncOps } = makeFs(ops, errno);
        const fs = { id: ops.id, errno, async: freeze(asyncOps) };
        if (sync) fs.sync = freeze(raw);
        return Promise.resolve(freeze(fs));
      },
      narrow(next) {
        const root = own(next, 'root');
        if (root !== undefined && typeof root !== 'string') throw new TypeError('root must be a string');
        return makeFsCap({
          root: joinPath(spec.root, root),
          write: spec.write && own(next, 'write') !== false,
          sync: spec.sync && own(next, 'sync') !== false,
        });
      },
    });
  }

  // ---- env --------------------------------------------------------------

  function makeEnvCap(allow) {
    const visible = name => allow === null || allow.has(name);
    return freeze({
      args: () => freeze(native.env.args()),
      get: name => (typeof name === 'string' && visible(name)) ? native.env.get(name) : undefined,
      list: () => freeze(native.env.list().filter(visible)),
      narrow(next) {
        const list = own(next, 'allow');
        if (!Array.isArray(list)) throw new TypeError('allow must be an array of names');
        const names = new Set(list.filter(name => typeof name === 'string' && visible(name)));
        return makeEnvCap(names);
      },
    });
  }

  // ---- scope ------------------------------------------------------------

  function makeScopeCap(state) {
    function handle(id) {
      return freeze({
        run() {
          const errno = new Uint32Array(1);
          const promise = native.scope.run(errno, id);
          return errno[0] === 0 ? promise : Promise.reject(failure(errno[0]));
        },
        close() {
          const errno = new Uint32Array(1);
          native.scope.close(errno, id);
          if (errno[0] !== 0) throw failure(errno[0]);
        },
      });
    }
    return freeze({
      create(options) {
        const errno = new Uint32Array(1);
        const main = own(options, 'main');
        const map = own(options, 'importMap');
        const loader = own(options, 'loader');
        const preload = own(options, 'preload') ?? [];
        if (typeof main !== 'string' || (loader !== undefined && typeof loader !== 'function') || !Array.isArray(preload)) {
          return Promise.reject(failure(InvalidPath));
        }
        if (state.remaining <= 0) return Promise.reject(failure(Unsupported));
        let mapJson;
        try { mapJson = map === undefined ? undefined : JSON.stringify(map); } catch { return Promise.reject(failure(InvalidPath)); }
        const id = native.scope.create(errno, main, mapJson, loader);
        if (errno[0] !== 0) return Promise.reject(failure(errno[0]));
        state.remaining--;
        for (let i = 0; i < preload.length; i++) {
          const source = own(preload[i], 'source');
          if (typeof source !== 'string') { native.scope.close(errno, id); return Promise.reject(failure(InvalidPath)); }
          native.scope.preload(errno, id, source, 'preload:' + i, own(preload[i], 'values'));
          if (errno[0] !== 0) { const code = errno[0]; native.scope.close(new Uint32Array(1), id); return Promise.reject(failure(code)); }
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

  return freeze({
    fs: makeFsCap({ root: undefined, write: true, sync: true }),
    env: makeEnvCap(null),
    scope: makeScopeCap({ remaining: Infinity }),
  });
})
