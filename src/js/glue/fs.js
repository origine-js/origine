// `api.fs`: the fs capability factory. Evaluated as an expression by src/api/glue.zig:
// `(native, util) => makeFsCap`. `makeFsCap(spec)` returns a frozen `{ requestSync, requestAsync,
// narrow }`; each request binds the native ops of one grant (Zig natives + errno cell for sync,
// Rust natives on an io runtime for async) and returns the sync or async variant.
(native, { freeze, errno, take, failure, own, joinPath, ioHandles, closedIo, errors: { InvalidPath, BadHandle, AccessDenied } }) => {
  // Python-style open modes -> native bits (write 1, create 2, truncate 4,
  // exclusive 8). Handles always allow reading when writable, so `x` and `x+`
  // (and `w`/`w+`, `r+`/`rw`) are equivalent natively. `c` and `t` extend Python's
  // set for Rust-style options: create keeping contents, truncate without creating.
  const OPEN_MODES = freeze(
    Object.assign(Object.create(null), {
      r: 0,
      rw: 1,
      'r+': 1,
      w: 7,
      'w+': 7,
      x: 11,
      'x+': 11,
      c: 3,
      'c+': 3,
      t: 5,
      't+': 5,
    }),
  );
  // `undefined` means `r`; anything unknown is -1 (rejected as InvalidPath).
  const openBits = mode => (mode === undefined ? 0 : typeof mode === 'string' ? (OPEN_MODES[mode] ?? -1) : -1);

  const isString = value => typeof value === 'string';
  const isBytes = value => value instanceof Uint8Array;

  // Guest buffers for the zero-copy async reads: an ArrayBuffer or any view over one. The shape of
  // a view is captured BEFORE the native call (the native may detach its buffer), then rebuilt over
  // the ArrayBuffer the promise resolves with. Views are rebuilt with the intrinsic constructor
  // named by their toStringTag (not `value.constructor`, which a guest can spoof), so a subclass
  // of Uint8Array comes back as a plain Uint8Array.
  const TypedArray = Object.getPrototypeOf(Uint8Array);
  const typedTag = Object.getOwnPropertyDescriptor(TypedArray.prototype, Symbol.toStringTag).get;
  const viewKinds = freeze(
    Object.assign(Object.create(null), {
      Int8Array,
      Uint8Array,
      Uint8ClampedArray,
      Int16Array,
      Uint16Array,
      Int32Array,
      Uint32Array,
      Float32Array,
      Float64Array,
      BigInt64Array,
      BigUint64Array,
      DataView,
    }),
  );
  // `{ make(arrayBuffer) }` for a view or a bare ArrayBuffer; null for anything else.
  const shapeOf = value => {
    if (value instanceof ArrayBuffer) return freeze({ make: buffer => buffer });
    if (!ArrayBuffer.isView(value)) return null;
    const Kind = viewKinds[value instanceof DataView ? 'DataView' : typedTag.call(value)];
    if (Kind === undefined) return null;
    const { byteOffset, byteLength } = value;
    const length = Kind === DataView ? byteLength : byteLength / Kind.BYTES_PER_ELEMENT;
    return freeze({
      make(buffer) {
        // An empty view (or one whose buffer another call detached first) completes without I/O
        // and may come back over a detached buffer, which no view can wrap: give it an empty one.
        if (length === 0) {
          try {
            return new Kind(buffer, byteOffset, 0);
          } catch {
            return new Kind(new ArrayBuffer(0));
          }
        }
        return new Kind(buffer, byteOffset, length);
      },
    });
  };
  const isOffset = value => typeof value === 'number' && Number.isSafeInteger(value) && value >= 0;

  // A handle is `{ kind, fs, id }`; anything else fails validation as null.
  const handleOfKind = kind => handle =>
    handle !== null && typeof handle === 'object' && handle.kind === kind && typeof handle.id === 'number' && typeof handle.fs === 'number'
      ? handle
      : null;
  const asDir = handleOfKind('dir');
  const asFile = handleOfKind('file');

  // Binds the native ops of one grant into the guest-visible operations. Each operation
  // validates its arguments (failing with InvalidPath through the errno cell), calls the
  // native and, when the native succeeded, shapes its result. The natives take a handle as
  // two arguments, `(fs, id)`. Operations that fail return undefined.
  function makeOps(ops) {
    const fsId = ops.id;
    const bad = () => {
      errno[0] = InvalidPath;
    };
    const ok = () => errno[0] === 0;
    const statOf = out => freeze({ kind: out[0], size: out[1] });

    const dirOps = {
      dirOpenFile(dir, path, flags) {
        const d = asDir(dir),
          bits = openBits(flags);
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
        const d = asDir(dir),
          n = asDir(newDir);
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

  // The async twin of `makeOps` over `native.fsAsync` (Rust, on an io runtime): same operation
  // names and argument validation, but it never touches the shared errno cell. Every operation
  // returns a promise; validation and completion failures reject with a frozen `{ errno, name }`
  // (the natives reject with that shape already). `fsId` is the async grant's id.
  //
  // Buffer semantics (phase 5): `fileWrite`/`filePwriteAll`/`fileWriteAll` DETACH the guest's
  // ArrayBuffer when it is eligible (not shared, not resizable, detachable) and write straight from
  // it; otherwise they copy at call time and the buffer stays usable. `fileRead`/`filePread` keep
  // the copying semantics (count result; the bytes are copied into `buffer` at completion).
  // `fileReadInto`/`filePreadInto` (BYOB) and `fileReadAlloc`/`filePreadAlloc` are the zero-copy reads.
  function makeAsyncOps(ops, fsId) {
    const bad = () => Promise.reject(failure(InvalidPath));
    // The `Dir.cwd()` sentinel `{0, 0}` names this grant's root.
    const root = handle => (handle !== null && handle.fs === 0 && handle.id === 0 ? { kind: 'dir', fs: fsId, id: 0 } : handle);
    const statOf = out => freeze({ kind: out[0], size: out[1] });
    const fileOf = id => freeze({ kind: 'file', fs: fsId, id });
    const dirOf = id => freeze({ kind: 'dir', fs: fsId, id });
    const entriesOf = flat => {
      // The native returns `[name, kind, name, kind, ...]`.
      const entries = [];
      for (let i = 0; i < flat.length; i += 2) entries.push(freeze({ name: flat[i], kind: flat[i + 1] }));
      return freeze(entries);
    };

    const dirOps = {
      dirOpenFile(dir, path, flags) {
        const d = asDir(root(dir)),
          bits = openBits(flags);
        if (d === null || !isString(path) || bits < 0) return bad();
        return ops.openFile(d.fs, d.id, path, bits).then(fileOf);
      },
      dirOpenDir(dir, path) {
        const d = asDir(root(dir));
        if (d === null || !isString(path)) return bad();
        return ops.openDir(d.fs, d.id, path).then(dirOf);
      },
      dirClose(dir) {
        const d = asDir(root(dir));
        if (d === null) return bad();
        return ops.closeDir(d.fs, d.id);
      },
      dirStat(dir, path) {
        const d = asDir(root(dir));
        if (d === null || !isString(path)) return bad();
        return ops.stat(d.fs, d.id, path).then(statOf);
      },
      dirRead(dir) {
        const d = asDir(root(dir));
        if (d === null) return bad();
        return ops.readDir(d.fs, d.id).then(entriesOf);
      },
      dirCreateDir(dir, path) {
        const d = asDir(root(dir));
        if (d === null || !isString(path)) return bad();
        return ops.createDir(d.fs, d.id, path);
      },
      dirCreateDirPath(dir, path) {
        const d = asDir(root(dir));
        if (d === null || !isString(path)) return bad();
        return ops.createDirPath(d.fs, d.id, path);
      },
      dirDeleteFile(dir, path) {
        const d = asDir(root(dir));
        if (d === null || !isString(path)) return bad();
        return ops.deleteFile(d.fs, d.id, path);
      },
      dirDeleteDir(dir, path) {
        const d = asDir(root(dir));
        if (d === null || !isString(path)) return bad();
        return ops.deleteDir(d.fs, d.id, path);
      },
      dirDeleteTree(dir, path) {
        const d = asDir(root(dir));
        if (d === null || !isString(path)) return bad();
        return ops.deleteTree(d.fs, d.id, path);
      },
      dirRename(dir, oldPath, newDir, newPath) {
        const d = asDir(root(dir)),
          n = asDir(root(newDir));
        if (d === null || n === null || !isString(oldPath) || !isString(newPath)) return bad();
        return ops.rename(d.fs, d.id, oldPath, n.fs, n.id, newPath);
      },
    };

    // Resolves `{ bytes, buffer }` (frozen) where `buffer` is a view of the same kind, byteOffset and
    // length as `view` over the ArrayBuffer the native hands back (the guest's `view` is detached
    // when the buffer was pinned; it is untouched when the host copied instead).
    const filled = (shape, pending) => pending.then(done => freeze({ bytes: done.bytes, buffer: shape.make(done.buffer) }));

    const fileOps = {
      fileClose(file) {
        const f = asFile(file);
        if (f === null) return bad();
        return ops.close(f.fs, f.id);
      },
      fileStat(file) {
        const f = asFile(file);
        if (f === null) return bad();
        return ops.fileStat(f.fs, f.id).then(statOf);
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
      // Zero-copy BYOB reads: `view` is an ArrayBuffer or a view; when eligible its buffer is
      // detached (the guest's `view` becomes empty) and the promise resolves a frozen
      // `{ bytes, buffer }`, `buffer` being a view of the same kind over the returned memory.
      fileReadInto(file, view) {
        const f = asFile(file),
          shape = shapeOf(view);
        if (f === null || shape === null) return bad();
        return filled(shape, ops.fileReadInto(f.fs, f.id, view));
      },
      filePreadInto(file, view, offset) {
        const f = asFile(file),
          shape = shapeOf(view);
        if (f === null || shape === null || !isOffset(offset)) return bad();
        return filled(shape, ops.filePreadInto(f.fs, f.id, view, offset));
      },
      // Host-allocated reads: resolve a Uint8Array of exactly the bytes read (at most `length`).
      fileReadAlloc(file, length) {
        const f = asFile(file);
        if (f === null || !isOffset(length)) return bad();
        return ops.fileReadAlloc(f.fs, f.id, length);
      },
      filePreadAlloc(file, length, offset) {
        const f = asFile(file);
        if (f === null || !isOffset(length) || !isOffset(offset)) return bad();
        return ops.filePreadAlloc(f.fs, f.id, length, offset);
      },
      fileWriteAll(file, bytes) {
        const f = asFile(file);
        if (f === null || !isBytes(bytes)) return bad();
        return ops.writeAll(f.fs, f.id, bytes);
      },
      fileWrite(file, bytes) {
        const f = asFile(file);
        if (f === null || !isBytes(bytes)) return bad();
        return ops.fileWrite(f.fs, f.id, bytes);
      },
      filePwriteAll(file, bytes, offset) {
        const f = asFile(file);
        if (f === null || !isBytes(bytes)) return bad();
        return ops.filePwriteAll(f.fs, f.id, bytes, offset);
      },
      fileSetLength(file, length) {
        const f = asFile(file);
        if (f === null) return bad();
        return ops.fileSetLength(f.fs, f.id, length);
      },
      fileSync(file) {
        const f = asFile(file);
        if (f === null) return bad();
        return ops.fileSync(f.fs, f.id);
      },
    };

    return { ...dirOps, ...fileOps };
  }

  // `{ root, write }` of a request hint against the cap's spec; null when `root` is malformed.
  function grantOf(spec, hint) {
    let root = own(hint, 'root');
    if (root !== undefined && typeof root !== 'string') return null;
    root = joinPath(spec.root, root);
    return { root, write: own(hint, 'write') === true && spec.write };
  }

  function makeFsCap(spec) {
    return freeze({
      // Blocking variant on the isolate thread (std.Io, errno cell). Throws a frozen
      // `{ errno, name }` when denied.
      requestSync(hint) {
        const grant = grantOf(spec, hint);
        if (grant === null) throw failure(InvalidPath);
        if (!spec.sync) throw failure(AccessDenied);
        const ops = native.fsRequest(grant.root, grant.write);
        if (errno[0] !== 0) throw failure(take());
        return freeze({ kind: 'sync', id: ops.id, errno, ...makeOps(ops) });
      },
      // Genuinely asynchronous variant on `io`, an `api.io` handle of this scope (the grant
      // runs its operations on that runtime). Rejects BadHandle (missing, closed or foreign io),
      // AccessDenied (not granted), InvalidPath, or the native's failure.
      requestAsync(hint) {
        const io = own(hint, 'io');
        if (io === undefined || io === null || typeof io !== 'object' || !ioHandles.has(io) || closedIo.has(io))
          return Promise.reject(failure(BadHandle));
        const grant = grantOf(spec, hint);
        if (grant === null) return Promise.reject(failure(InvalidPath));
        if (!spec.async || native.fsAsync === undefined) return Promise.reject(failure(AccessDenied));
        return native.fsAsync
          .request(io.id, grant.root === undefined || grant.root === '' ? '.' : grant.root, grant.write)
          .then(granted => freeze({ kind: 'async', id: granted.id, ...makeAsyncOps(native.fsAsync, granted.id) }));
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
};
