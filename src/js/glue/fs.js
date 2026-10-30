// `api.fs`: the fs capability factory. An ES module factory used by index.js:
// Its default export reads the per-realm native and shared helpers through imports;
// `makeFsCap(spec)` returns a frozen `{ requestSync, requestAsync }`;
// a sync request returns the grant the host built (Zig natives + errno cell); an async one wraps the
// Rust natives of its grant on an io runtime in promise-returning operations. `spec` is the embedder's
// ceiling (`Config.fs`): `{ root, write, sync, async }`.
//
// A request names the access it wants, `access: 'r' | 'w' | 'rw'` (required). A request above the
// ceiling is denied (PermissionDenied), never silently downgraded. Native handles are readable
// whenever they are writable, so a write-only grant ('w') is enforced by the grant itself: it denies
// everything that observes what exists (reads, stat, directory listings, opening read-only).
import { records, recordOf, failure, own, joinPath, ioHandles, closedIo, shared, freeze, errors, settled, settling } from './util.js';
const { InvalidInput, BadHandle, PermissionDenied } = errors;
// Static open-mode mapping shared by every fs capability built in this realm.
const OPEN_MODES = Object.freeze(
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
// `undefined` means `r`; anything unknown is -1 (rejected as InvalidInput).
const openBits = mode => (mode === undefined ? 0 : typeof mode === 'string' ? (OPEN_MODES[mode] ?? -1) : -1);
const isString = value => typeof value === 'string';
const isBytes = value => value instanceof Uint8Array;
const isOffset = value => typeof value === 'number' && Number.isSafeInteger(value) && value >= 0;

// Guest buffers for zero-copy async reads. Capture a view's shape before the native call (it may
// detach the buffer), then rebuild it over the returned ArrayBuffer using the intrinsic kind.
const TypedArray = Object.getPrototypeOf(Uint8Array);
const typedTag = Object.getOwnPropertyDescriptor(TypedArray.prototype, Symbol.toStringTag).get;
const viewKinds = Object.freeze(
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
const shapeOf = value => {
  if (value instanceof ArrayBuffer) return Object.freeze({ make: buffer => buffer });
  if (!ArrayBuffer.isView(value)) return null;
  const Kind = viewKinds[value instanceof DataView ? 'DataView' : typedTag.call(value)];
  if (Kind === undefined) return null;
  const { byteOffset, byteLength } = value;
  const length = Kind === DataView ? byteLength : byteLength / Kind.BYTES_PER_ELEMENT;
  return Object.freeze({
    make(buffer) {
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

export default (native, { errno, take }) => {
  // Read private JS reference state without crossing into native code.
  const handleOfKind = kind => handle => records.unwrap(handle, kind === 'dir' ? 'DirRef' : 'FileRef') ?? null;
  const asDir = handleOfKind('dir');
  const asFile = handleOfKind('file');

  const makeGrant = records.define('FsGrant');
  const fileOf = (fs, id) => recordOf('FileRef', { kind: 'file', fs, id });
  const dirOf = (fs, id) => recordOf('DirRef', { kind: 'dir', fs, id });
  const statOf = out => recordOf('Stat', { kind: out[0], size: out[1] });
  const syncEntriesOf = entries => freeze(entries.map(entry => recordOf('DirEntry', entry)));

  // Public sync operations unwrap JS-private state and call one grant-bound native.
  // Native checks remain responsible for ownership, access, liveness, and arguments.
  function makeSyncOps(raw) {
    const bad = () => {
      errno[0] = InvalidInput;
      return undefined;
    };
    const refOp = (name, unwrap, wrap) => (handle, a, b, c) => {
      const ref = unwrap(handle);
      if (ref === null) return bad();
      const result = raw[name](ref.fs, ref.id, a, b, c);
      if (errno[0] !== 0) return undefined;
      return wrap === undefined ? result : wrap(result);
    };
    const ops = {};
    for (const name of ['dirClose', 'dirCreateDir', 'dirCreateDirPath', 'dirDeleteFile', 'dirDeleteDir', 'dirDeleteTree'])
      ops[name] = refOp(name, asDir);
    for (const name of [
      'fileClose',
      'fileReadAll',
      'fileRead',
      'filePread',
      'fileWriteAll',
      'fileWrite',
      'filePwriteAll',
      'fileWriteMoveAll',
      'fileWriteMove',
      'filePwriteMoveAll',
      'fileSetLength',
      'fileSync',
    ])
      ops[name] = refOp(name, asFile);
    ops.dirOpenFile = refOp('dirOpenFile', asDir, id => fileOf(raw.id, id));
    ops.dirOpenDir = refOp('dirOpenDir', asDir, id => dirOf(raw.id, id));
    ops.dirStat = refOp('dirStat', asDir, statOf);
    ops.dirSymlinkStat = refOp('dirSymlinkStat', asDir, statOf);
    ops.fileStat = refOp('fileStat', asFile, statOf);
    ops.dirRead = refOp('dirRead', asDir, syncEntriesOf);
    ops.dirRename = (dir, oldPath, newDir, newPath) => {
      const from = asDir(dir),
        to = asDir(newDir);
      if (from === null || to === null) return bad();
      return raw.dirRename(from.fs, from.id, oldPath, to.fs, to.id, newPath);
    };
    return ops;
  }

  // The async grant's operations over `native.fsAsync` (Rust, on an io runtime): same operation
  // names and argument validation, but it never touches the shared errno cell. Every operation
  // returns a promise; validation and completion failures reject with OrigineError subclasses.
  // `fsId` is the async grant's id.
  //
  // Buffer semantics: `fileWrite`/`filePwriteAll`/`fileWriteAll` ALWAYS copy the bytes at call time
  // and never touch the guest's buffer. `fileWriteMove`/`filePwriteMoveAll`/`fileWriteMoveAll` are
  // the explicit transfers: they DETACH the guest's ArrayBuffer (the whole buffer, not only a view's
  // window) and write straight from its memory, and fail Unsupported (with the buffer untouched, no
  // silent copy) when it cannot be detached (shared, resizable, WebAssembly memory). `fileRead`/
  // `filePread` copy too (count result; the bytes are copied into `buffer` at completion).
  // `fileReadInto`/`filePreadInto` (BYOB) and `fileReadAlloc`/`filePreadAlloc` are the zero-copy reads.
  function makeAsyncOps(natives, fsId) {
    const ops = settling(natives);
    const bad = () => Promise.reject(failure(InvalidInput));
    // Unwrap before observing any fields: forged references never invoke guest getters.
    const root = handle => {
      const ref = asDir(handle);
      return ref !== null && ref.fs === 0 && ref.id === 0 ? { fs: fsId, id: 0 } : ref;
    };
    const statOf = out => recordOf('Stat', { kind: out[0], size: out[1] });
    const fileOf = id => recordOf('FileRef', { kind: 'file', fs: fsId, id });
    const dirOf = id => recordOf('DirRef', { kind: 'dir', fs: fsId, id });
    const entriesOf = flat => {
      // The native returns `[name, kind, name, kind, ...]`.
      const entries = [];
      for (let i = 0; i < flat.length; i += 2) entries.push(recordOf('DirEntry', { name: flat[i], kind: flat[i + 1] }));
      return freeze(entries);
    };

    const dirOps = {
      dirOpenFile(dir, path, flags) {
        const d = root(dir),
          bits = openBits(flags);
        if (d === null || !isString(path) || bits < 0) return bad();
        return ops.openFile(d.fs, d.id, path, bits).then(fileOf);
      },
      dirOpenDir(dir, path) {
        const d = root(dir);
        if (d === null || !isString(path)) return bad();
        return ops.openDir(d.fs, d.id, path).then(dirOf);
      },
      dirClose(dir) {
        const d = root(dir);
        if (d === null) return bad();
        return ops.closeDir(d.fs, d.id);
      },
      dirStat(dir, path) {
        const d = root(dir);
        if (d === null || !isString(path)) return bad();
        return ops.stat(d.fs, d.id, path).then(statOf);
      },
      dirSymlinkStat(dir, path) {
        const d = root(dir);
        if (d === null || !isString(path)) return bad();
        return ops.symlinkStat(d.fs, d.id, path).then(statOf);
      },
      dirRead(dir) {
        const d = root(dir);
        if (d === null) return bad();
        return ops.readDir(d.fs, d.id).then(entriesOf);
      },
      dirCreateDir(dir, path) {
        const d = root(dir);
        if (d === null || !isString(path)) return bad();
        return ops.createDir(d.fs, d.id, path);
      },
      dirCreateDirPath(dir, path) {
        const d = root(dir);
        if (d === null || !isString(path)) return bad();
        return ops.createDirPath(d.fs, d.id, path);
      },
      dirDeleteFile(dir, path) {
        const d = root(dir);
        if (d === null || !isString(path)) return bad();
        return ops.deleteFile(d.fs, d.id, path);
      },
      dirDeleteDir(dir, path) {
        const d = root(dir);
        if (d === null || !isString(path)) return bad();
        return ops.deleteDir(d.fs, d.id, path);
      },
      dirDeleteTree(dir, path) {
        const d = root(dir);
        if (d === null || !isString(path)) return bad();
        return ops.deleteTree(d.fs, d.id, path);
      },
      dirRename(dir, oldPath, newDir, newPath) {
        const d = root(dir),
          n = root(newDir);
        if (d === null || n === null || !isString(oldPath) || !isString(newPath)) return bad();
        return ops.rename(d.fs, d.id, oldPath, n.fs, n.id, newPath);
      },
    };

    // Resolves a JS ReadResult with read-only bytes and buffer fields where `buffer` is a view of the same kind, byteOffset and
    // length as `view` over the ArrayBuffer the native hands back (the guest's `view` is detached
    // when the buffer was pinned; it is untouched when the host copied instead).
    const filled = (shape, pending) => pending.then(done => recordOf('ReadResult', { bytes: done.bytes, buffer: shape.make(done.buffer) }));

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
      fileWriteMoveAll(file, bytes) {
        const f = asFile(file);
        if (f === null || !isBytes(bytes)) return bad();
        return ops.writeMoveAll(f.fs, f.id, bytes);
      },
      fileWriteMove(file, bytes) {
        const f = asFile(file);
        if (f === null || !isBytes(bytes)) return bad();
        return ops.fileWriteMove(f.fs, f.id, bytes);
      },
      filePwriteMoveAll(file, bytes, offset) {
        const f = asFile(file);
        if (f === null || !isBytes(bytes)) return bad();
        return ops.filePwriteMoveAll(f.fs, f.id, bytes, offset);
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

  // Access bits of the natives: 1 read, 2 write.
  const ACCESS = freeze(Object.assign(Object.create(null), { r: 1, w: 2, rw: 3 }));

  // `{ root, access }` of a request hint against the cap's spec, or the errno of a bad or denied
  // request: InvalidInput for a malformed `root` or a missing / unknown `access`, PermissionDenied
  // for a write the embedder's ceiling (`spec.write`) does not allow (never downgraded).
  function grantOf(spec, hint) {
    let root = own(hint, 'root');
    if (root !== undefined && typeof root !== 'string') return InvalidInput;
    const name = own(hint, 'access');
    const access = typeof name === 'string' ? ACCESS[name] : undefined;
    if (access === undefined) return InvalidInput;
    if (access & 2 && !spec.write) return PermissionDenied;
    root = joinPath(spec.root, root);
    return { root, access };
  }

  function makeFsCap(spec) {
    // The graph glue reads source files through the async grants' natives.
    Object.defineProperty(shared, 'fsAsync', { get: () => native.fsAsync });
    return freeze({
      // Blocking variant on the isolate thread (std.Io, errno cell). Throws a frozen
      // OrigineError subclasses when denied.
      requestSync(hint) {
        const grant = grantOf(spec, hint);
        if (typeof grant === 'number') throw failure(grant);
        if (!spec.sync) throw failure(PermissionDenied);
        // The host stamps a private raw grant. The JS class exposes wrapped operations and the
        // shared errno cell; the raw grant stays in private state for authority consumers.
        const granted = native.fsRequest(grant.root, grant.access);
        if (errno[0] !== 0) throw failure(take());
        return makeGrant({ kind: granted.kind, id: granted.id, errno, ...makeSyncOps(granted) }, granted);
      },
      // Genuinely asynchronous variant on `io`, an `api.io` handle of this scope (the grant
      // runs its operations on that runtime). Rejects BadHandle (missing, closed or foreign io),
      // PermissionDenied (not granted), InvalidInput, or the native's failure.
      requestAsync(hint) {
        const io = own(hint, 'io');
        if (io === undefined || io === null || typeof io !== 'object' || !ioHandles.has(io) || closedIo.has(io))
          return Promise.reject(failure(BadHandle));
        const grant = grantOf(spec, hint);
        if (typeof grant === 'number') return Promise.reject(failure(grant));
        if (!spec.async || native.fsAsync === undefined) return Promise.reject(failure(PermissionDenied));
        // `io.close()` tells the host, which then refuses the grants opened on that io as an authority.
        shared.asyncFsClosed ??= handle => native.fsAsyncClosed(handle.id);
        // The host opens the grant on the Rust runtime and builds the grant object from its answer.
        return settled(
          native.fsRequestAsync(native.fsAsync.request, io.id, grant.root === undefined || grant.root === '' ? '.' : grant.root, grant.access),
        )
          .then(granted => makeGrant({ kind: granted.kind, id: granted.id, ...makeAsyncOps(native.fsAsync, granted.id) }, granted));
      },
    });
  }

  return makeFsCap;
};
