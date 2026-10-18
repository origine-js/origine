// `@engine/std/io`: Zig-style Io vocabulary for the init context.
// Pure data: holding any of these values confers no authority. The errno table
// must match `Errno` in api.zig.
const freeze = Object.freeze;

const ERRNO = {
  FileNotFound: 1,
  AccessDenied: 2,
  NotDir: 3,
  IsDir: 4,
  PathAlreadyExists: 5,
  BadHandle: 6,
  StaleHandle: 7,
  InvalidPath: 8,
  NoSpaceLeft: 9,
  Unsupported: 10,
  FileTooBig: 11,
  Unexpected: 255,
};
const NAMES = new Map(Object.entries(ERRNO).map(([name, code]) => [code, name]));

/// Errno values with Zig-style names. `is` accepts a number or any `{ errno }`.
export const IoError = freeze({
  ...ERRNO,
  name: code => NAMES.get(code) ?? 'Unexpected',
  is: (value, code) => (typeof value === 'number' ? value : value?.errno) === code,
  /// Throws a frozen `{ errno, name }` when a sync call left a non-zero errno in
  /// `fs.errno`, and resets the state. Returns `value` otherwise.
  check(fs, value) {
    const code = fs.errno[0];
    if (code === 0) return value;
    fs.errno[0] = 0;
    throw freeze({ errno: code, name: NAMES.get(code) ?? 'Unexpected' });
  },
});

/// Byte limit with `std.Io.Limit` semantics. `unlimited` is Infinity (maxInt(usize)).
export const Limit = freeze({
  unlimited: Infinity,
  nothing: 0,
  limited(n) {
    if (!Number.isSafeInteger(n) || n < 0) throw new RangeError('limit must be a non-negative safe integer');
    return n;
  },
});

export const FileKind = freeze({ file: 1, directory: 2, sym_link: 3, other: 4 });

// ---- Zig-style Dir / File ----------------------------------------------------
//
// `Dir` and `File` descriptors carry Zig's method names. As in Zig, every method
// takes the `io` first; here `io` is `fs.sync` (blocking, throws an IoError value)
// or `fs.async` (returns a promise that rejects with one). Descriptors stay
// authority-free: the fs object behind `io` does the work and checks the grant.

const isSync = io => io.kind === 'sync';
// Finishes an fs op result for `io`: sync results are errno-checked and mapped,
// async results (promises) are chained. Call sites pass fixed arguments straight
// to `io[name](...)`, so no argument arrays are allocated.
const done = (io, value, then) => {
  if (isSync(io)) {
    const checked = IoError.check(io, value);
    return then === undefined ? checked : then(checked);
  }
  return then === undefined ? value : value.then(then);
};
// Sequences steps for both modes: `steps` is a generator yielding op results.
const sequence = (io, steps) => {
  if (isSync(io)) {
    const it = steps();
    let r = it.next();
    while (!r.done) r = it.next(r.value);
    return r.value;
  }
  const it = steps();
  const next = (method, arg) => {
    let r;
    try { r = it[method](arg); } catch (e) { return Promise.reject(e); }
    if (r.done) return Promise.resolve(r.value);
    return Promise.resolve(r.value).then(v => next('next', v), e => next('throw', e));
  };
  return next('next');
};

const MODES = { read_only: 'read', write_only: 'write', read_write: 'readwrite', read: 'read', write: 'write', readwrite: 'readwrite' };
const READ = Object.freeze({ mode: 'read' });
const UNLIMITED = Object.freeze({ limit: Infinity });
const openFlags = options => options === undefined ? READ : { mode: MODES[options.mode ?? 'read_only'] ?? 'read' };
const wrapDir = d => new DirImpl(d.fs, d.id);
const wrapFile = f => new FileImpl(f.fs, f.id);

class DirImpl {
  constructor(fs, id) {
    this.kind = 'dir';
    this.fs = fs;
    this.id = id;
    freeze(this);
  }
  /// Zig `Dir.openFile`. options: `{ mode: 'read_only' | 'write_only' | 'read_write' }`.
  openFile(io, path, options) { return done(io, io.dirOpenFile(this, path, openFlags(options)), wrapFile); }
  /// Zig `Dir.createFile`. options: `{ read = false, truncate = true, exclusive = false }`.
  createFile(io, path, options = {}) {
    const flags = { mode: options.read ? 'readwrite' : 'write', create: true, truncate: options.truncate ?? true, exclusive: options.exclusive ?? false };
    return done(io, io.dirOpenFile(this, path, flags), wrapFile);
  }
  openDir(io, path) { return done(io, io.dirOpenDir(this, path), wrapDir); }
  close(io) { return done(io, io.dirClose(this)); }
  createDir(io, path) { return done(io, io.dirCreateDir(this, path)); }
  createDirPath(io, path) { return done(io, io.dirCreateDirPath(this, path)); }
  /// Zig `Dir.createDirPathOpen`.
  createDirPathOpen(io, path) {
    return sequence(io, function* () { yield done(io, io.dirCreateDirPath(this, path)); return yield done(io, io.dirOpenDir(this, path), wrapDir); }.bind(this));
  }
  deleteFile(io, path) { return done(io, io.dirDeleteFile(this, path)); }
  deleteDir(io, path) { return done(io, io.dirDeleteDir(this, path)); }
  deleteTree(io, path) { return done(io, io.dirDeleteTree(this, path)); }
  /// Zig `Dir.rename(old_dir, old_sub_path, new_dir, new_sub_path, io)`, here `oldDir.rename(io, old, newDir, new)`.
  rename(io, oldPath, newDir, newPath) { return done(io, io.dirRename(this, oldPath, newDir, newPath)); }
  /// Zig `Dir.stat`: metadata of this directory.
  stat(io) { return done(io, io.dirStat(this, '')); }
  /// Zig `Dir.statFile`: symlinks are not followed.
  statFile(io, path) { return done(io, io.dirStat(this, path)); }
  /// Zig `Dir.access`: rejects with FileNotFound (etc.) when the path is not reachable.
  access(io, path) { return done(io, io.dirStat(this, path), () => undefined); }
  /// Zig `Dir.iterate` collected into an array of `{ name, kind }` (iterable).
  iterate(io) { return done(io, io.dirRead(this)); }
  /// Zig `Dir.readFileAlloc`: whole file as a Uint8Array, at most `limit` bytes.
  readFile(io, path, limit = Limit.unlimited) {
    if (isSync(io)) {
      const file = this.openFile(io, path);
      try { return file.readAll(io, limit); } finally { file.close(io); }
    }
    const dir = this;
    return sequence(io, function* () {
      const file = yield dir.openFile(io, path);
      try { return yield file.readAll(io, limit); } finally { yield file.close(io); }
    });
  }
  /// Zig `Dir.writeFile(io, { sub_path, data, flags })`.
  writeFile(io, { sub_path, data, flags } = {}) {
    if (isSync(io)) {
      const file = this.createFile(io, sub_path, flags);
      try { file.writeStreamingAll(io, data); } finally { file.close(io); }
      return undefined;
    }
    const dir = this;
    return sequence(io, function* () {
      const file = yield dir.createFile(io, sub_path, flags);
      try { yield file.writeStreamingAll(io, data); } finally { yield file.close(io); }
    });
  }
}

class FileImpl {
  constructor(fs, id) {
    this.kind = 'file';
    this.fs = fs;
    this.id = id;
    freeze(this);
  }
  close(io) { return done(io, io.fileClose(this)); }
  stat(io) { return done(io, io.fileStat(this)); }
  length(io) { return done(io, io.fileStat(this), s => s.size); }
  /// Zig `File.readStreaming` into one buffer: returns the byte count, 0 at end.
  readStreaming(io, buffer) { return done(io, io.fileRead(this, buffer)); }
  readPositional(io, buffer, offset) { return done(io, io.filePread(this, buffer, offset)); }
  /// Zig `File.readPositionalAll`: fills `buffer` from `offset` until full or end; returns the count.
  readPositionalAll(io, buffer, offset) {
    const file = this;
    return sequence(io, function* () {
      let total = 0;
      while (total < buffer.length) {
        const n = yield file.readPositional(io, buffer.subarray(total), offset + total);
        if (n === 0) break;
        total += n;
      }
      return total;
    });
  }
  /// Everything from the current position, at most `limit` bytes (`Limit` semantics).
  readAll(io, limit = Limit.unlimited) { return done(io, io.fileReadAll(this, limit === Infinity ? UNLIMITED : { limit })); }
  /// Zig `File.writeStreaming` of one slice: returns the byte count (may be partial).
  writeStreaming(io, bytes) { return done(io, io.fileWrite(this, bytes)); }
  writeStreamingAll(io, bytes) { return done(io, io.fileWriteAll(this, bytes)); }
  writePositionalAll(io, bytes, offset) { return done(io, io.filePwriteAll(this, bytes, offset)); }
  setLength(io, length) { return done(io, io.fileSetLength(this, length)); }
  sync(io) { return done(io, io.fileSync(this)); }
}
freeze(DirImpl.prototype);
freeze(FileImpl.prototype);
freeze(DirImpl);
freeze(FileImpl);

const CWD = new DirImpl(0, 0);

/// Descriptors name something inside one fs object; `cwd()` is the sentinel each
/// fs resolves to its own root.
export const Dir = freeze({
  cwd: () => CWD,
  at: (fs, id) => new DirImpl(fs, id),
  is: value => value instanceof DirImpl,
});

export const File = freeze({
  at: (fs, id) => new FileImpl(fs, id),
  is: value => value instanceof FileImpl,
});
