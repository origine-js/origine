// `api.fs`: the fs capability factory. Evaluated as an expression by src/api/glue.zig:
// `(native, util) => makeFsCap`. `makeFsCap(spec)` returns a frozen `{ request, narrow }`;
// `request` binds the native ops of one grant and returns the sync/async variants.
(native, { freeze, errno, take, failure, own, joinPath, errors: { InvalidPath } }) => {
  // Python-style open modes -> native bits (write 1, create 2, truncate 4,
  // exclusive 8). Handles always allow reading when writable, so `x` and `x+`
  // (and `w`/`w+`, `r+`/`rw`) are equivalent natively. `c` and `t` extend Python's
  // set for Rust-style options: create keeping contents, truncate without creating.
  const OPEN_MODES = freeze(Object.assign(Object.create(null), {
    r: 0,
    rw: 1, 'r+': 1,
    w: 7, 'w+': 7,
    x: 11, 'x+': 11,
    c: 3, 'c+': 3,
    t: 5, 't+': 5,
  }));
  // `undefined` means `r`; anything unknown is -1 (rejected as InvalidPath).
  const openBits = mode => mode === undefined ? 0 : typeof mode === 'string' ? (OPEN_MODES[mode] ?? -1) : -1;

  const isString = value => typeof value === 'string';
  const isBytes = value => value instanceof Uint8Array;

  // A handle is `{ kind, fs, id }`; anything else fails validation as null.
  const handleOfKind = kind => handle =>
    (handle !== null && typeof handle === 'object' && handle.kind === kind && typeof handle.id === 'number' && typeof handle.fs === 'number') ? handle : null;
  const asDir = handleOfKind('dir');
  const asFile = handleOfKind('file');

  // Binds the native ops of one grant into the guest-visible operations. Each operation
  // validates its arguments (failing with InvalidPath through the errno cell), calls the
  // native and, when the native succeeded, shapes its result. The natives take a handle as
  // two arguments, `(fs, id)`. Operations that fail return undefined.
  function makeOps(ops) {
    const fsId = ops.id;
    const bad = () => { errno[0] = InvalidPath; };
    const ok = () => errno[0] === 0;
    const statOf = out => freeze({ kind: out[0], size: out[1] });

    const dirOps = {
      dirOpenFile(dir, path, flags) {
        const d = asDir(dir), bits = openBits(flags);
        if (d === null || !isString(path) || bits < 0) return bad();
        const id = ops.openFile(d.fs, d.id, path, bits);
        return ok() ? freeze({ kind: 'file', fs: fsId, id }) : undefined;
      },
      dirOpenDir(dir, path) {
        const d = asDir(dir);
        if (d === null || !isString(path)) return bad();
        const id = ops.openDir(d.fs, d.id, path);
        return ok() ? freeze({ kind: 'dir', fs: fsId, id }) : undefined;
      },
      dirClose(dir) {
        const d = asDir(dir);
        if (d === null) return bad();
        ops.closeDir(d.fs, d.id);
      },
      dirStat(dir, path) {
        const d = asDir(dir);
        if (d === null || !isString(path)) return bad();
        const out = ops.stat(d.fs, d.id, path);
        return ok() ? statOf(out) : undefined;
      },
      dirRead(dir) {
        const d = asDir(dir);
        if (d === null) return bad();
        const flat = ops.readDir(d.fs, d.id);
        if (!ok()) return undefined;
        // The native returns `[name, kind, name, kind, ...]`.
        const entries = [];
        for (let i = 0; i < flat.length; i += 2) entries.push(freeze({ name: flat[i], kind: flat[i + 1] }));
        return freeze(entries);
      },
      dirCreateDir(dir, path) {
        const d = asDir(dir);
        if (d === null || !isString(path)) return bad();
        ops.createDir(d.fs, d.id, path);
      },
      dirCreateDirPath(dir, path) {
        const d = asDir(dir);
        if (d === null || !isString(path)) return bad();
        ops.createDirPath(d.fs, d.id, path);
      },
      dirDeleteFile(dir, path) {
        const d = asDir(dir);
        if (d === null || !isString(path)) return bad();
        ops.deleteFile(d.fs, d.id, path);
      },
      dirDeleteDir(dir, path) {
        const d = asDir(dir);
        if (d === null || !isString(path)) return bad();
        ops.deleteDir(d.fs, d.id, path);
      },
      dirDeleteTree(dir, path) {
        const d = asDir(dir);
        if (d === null || !isString(path)) return bad();
        ops.deleteTree(d.fs, d.id, path);
      },
      dirRename(dir, oldPath, newDir, newPath) {
        const d = asDir(dir), n = asDir(newDir);
        if (d === null || n === null || !isString(oldPath) || !isString(newPath)) return bad();
        ops.rename(d.fs, d.id, oldPath, n.fs, n.id, newPath);
      },
    };

    const fileOps = {
      fileClose(file) {
        const f = asFile(file);
        if (f === null) return bad();
        ops.close(f.fs, f.id);
      },
      fileStat(file) {
        const f = asFile(file);
        if (f === null) return bad();
        const out = ops.fileStat(f.fs, f.id);
        return ok() ? statOf(out) : undefined;
      },
      fileReadAll(file, options) {
        const f = asFile(file);
        if (f === null) return bad();
        const limit = (options === undefined ? undefined : options.limit) ?? Infinity;
        if (typeof limit !== 'number' || !(limit >= 0)) return bad();
        return ops.readAll(f.fs, f.id, limit);
      },
      fileRead(file, buffer) {
        const f = asFile(file);
        if (f === null || !isBytes(buffer)) return bad();
        return ops.fileRead(f.fs, f.id, buffer);
      },
      filePread(file, buffer, offset) {
        const f = asFile(file);
        if (f === null || !isBytes(buffer)) return bad();
        return ops.filePread(f.fs, f.id, buffer, offset);
      },
      fileWriteAll(file, bytes) {
        const f = asFile(file);
        if (f === null || !isBytes(bytes)) return bad();
        ops.writeAll(f.fs, f.id, bytes);
      },
      fileWrite(file, bytes) {
        const f = asFile(file);
        if (f === null || !isBytes(bytes)) return bad();
        return ops.fileWrite(f.fs, f.id, bytes);
      },
      filePwriteAll(file, bytes, offset) {
        const f = asFile(file);
        if (f === null || !isBytes(bytes)) return bad();
        ops.filePwriteAll(f.fs, f.id, bytes, offset);
      },
      fileSetLength(file, length) {
        const f = asFile(file);
        if (f === null) return bad();
        ops.fileSetLength(f.fs, f.id, length);
      },
      fileSync(file) {
        const f = asFile(file);
        if (f === null) return bad();
        ops.fileSync(f.fs, f.id);
      },
    };

    return { ...dirOps, ...fileOps };
  }

  // Promise-returning twin of `syncOps`: same names, same validation. Draft-1 runs the
  // operation inline on the isolate thread and settles immediately; a host work queue
  // replaces this later without changing the surface.
  function toAsync(syncOps) {
    const asyncOps = {};
    for (const [name, op] of Object.entries(syncOps)) {
      // Fixed arity (the widest op takes four): no rest/spread allocation per call.
      asyncOps[name] = (a, b, c, d) => {
        errno[0] = 0;
        let value;
        try { value = op(a, b, c, d); } catch (e) { return Promise.reject(e); }
        const code = take();
        return code !== 0 ? Promise.reject(failure(code)) : Promise.resolve(value);
      };
    }
    return asyncOps;
  }

  function makeFsCap(spec) {
    return freeze({
      request(hint) {
        let root = own(hint, 'root');
        if (root !== undefined && typeof root !== 'string') return Promise.reject(failure(InvalidPath));
        root = joinPath(spec.root, root);
        const write = own(hint, 'write') === true && spec.write;
        const ops = native.fsRequest(root, write);
        if (errno[0] !== 0) return Promise.reject(failure(take()));
        // `mode` picks the variants to return; omitted means async only.
        const mode = own(hint, 'mode');
        const wantAsync = mode === undefined ? true : own(mode, 'async') === true;
        const wantSync = own(mode, 'sync') === true;
        const syncOps = makeOps(ops);
        const fs = { id: ops.id, errno };
        if (wantAsync && spec.async) fs.async = freeze({ kind: 'async', ...toAsync(syncOps) });
        if (wantSync && spec.sync && ops.sync === true) fs.sync = freeze({ kind: 'sync', errno, ...syncOps });
        return Promise.resolve(fs);
      },
      narrow(next) {
        const root = own(next, 'root');
        if (root !== undefined && typeof root !== 'string') throw new TypeError('root must be a string');
        return makeFsCap({
          root: joinPath(spec.root, root),
          write: spec.write && own(next, 'write') !== false,
          async: spec.async && own(own(next, 'mode'), 'async') !== false,
          sync: spec.sync && own(own(next, 'mode'), 'sync') !== false,
        });
      },
    });
  }

  return makeFsCap;
}
