// `@engine/std/io`: Zig-style Io vocabulary for the init context.
// Pure data: holding any of these values confers no authority. The errno table
// must match `Errno` in api.zig.
import { quansync } from '@engine/std/quansync';

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
  InvalidData: 12,
  Unexpected: 255,
};
const NAMES = new Map(Object.entries(ERRNO).map(([name, code]) => [code, name]));

/// Errno values with Zig-style names. `is` accepts a number or any `{ errno }`.
export const IoError = freeze({
  ...ERRNO,
  name: code => NAMES.get(code) ?? 'Unexpected',
  is: (value, code) => (typeof value === 'number' ? value : value?.errno) === code,
  /// A frozen `{ errno, name }` error value for `code`.
  of: code => freeze({ errno: code, name: NAMES.get(code) ?? 'Unexpected' }),
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
// or `fs.async` (returns promises that reject with one). Descriptors stay
// authority-free: the fs object behind `io` does the work and checks the grant.
//
// Each method dispatches through a quansync leaf or composite by `io.kind`
// ('sync' | 'async'), and the same functions are exported as `ops` for other
// std modules to compose with `yield*`. Every op takes `(io, self, ...args)`.

const MODES = { read_only: 'read', write_only: 'write', read_write: 'readwrite', read: 'read', write: 'write', readwrite: 'readwrite' };
const READ = freeze({ mode: 'read' });
const UNLIMITED = freeze({ limit: Infinity });
const openFlags = options => options === undefined ? READ : { mode: MODES[options.mode ?? 'read_only'] ?? 'read' };
const createFlags = (options = {}) => ({ mode: options.read ? 'readwrite' : 'write', create: true, truncate: options.truncate ?? true, exclusive: options.exclusive ?? false });
const wrapDir = d => new DirImpl(d.fs, d.id);
const wrapFile = f => new FileImpl(f.fs, f.id);
const dropResult = () => undefined;
const sizeOf = stat => stat.size;

// One fs call as a quansync leaf. Natives take at most four arguments after errno.
const op = (name, wrap) => quansync({
  sync: (io, a, b, c, d) => {
    const value = IoError.check(io, io[name](a, b, c, d));
    return wrap === undefined ? value : wrap(value);
  },
  async: (io, a, b, c, d) => {
    const pending = io[name](a, b, c, d);
    return wrap === undefined ? pending : pending.then(wrap);
  },
});

const dirOpenFile = op('dirOpenFile', wrapFile);
const dirOpenDir = op('dirOpenDir', wrapDir);
const dirClose = op('dirClose');
const dirStat = op('dirStat');
const dirAccess = op('dirStat', dropResult);
const dirCreateDir = op('dirCreateDir');
const dirCreateDirPath = op('dirCreateDirPath');
const dirDeleteFile = op('dirDeleteFile');
const dirDeleteDir = op('dirDeleteDir');
const dirDeleteTree = op('dirDeleteTree');
const dirRename = op('dirRename');
const dirRead = op('dirRead');
const fileClose = op('fileClose');
const fileStat = op('fileStat');
const fileLength = op('fileStat', sizeOf);
const fileRead = op('fileRead');
const filePread = op('filePread');
const fileReadAll = op('fileReadAll');
const fileWrite = op('fileWrite');
const fileWriteAll = op('fileWriteAll');
const filePwriteAll = op('filePwriteAll');
const fileSetLength = op('fileSetLength');
const fileSync = op('fileSync');

const dirCreateDirPathOpen = quansync(function* (io, dir, path) {
  yield* dirCreateDirPath(io, dir, path);
  return yield* dirOpenDir(io, dir, path);
});

const dirReadFile = quansync(function* (io, dir, path, limit) {
  const file = yield* dirOpenFile(io, dir, path, READ);
  try {
    return yield* fileReadAll(io, file, limit === Infinity ? UNLIMITED : { limit });
  } finally {
    yield* fileClose(io, file);
  }
}, {
  // Hand-written sync path: no generator, no task objects.
  sync(io, dir, path, limit) {
    const file = dirOpenFile.sync(io, dir, path, READ);
    try { return fileReadAll.sync(io, file, limit === Infinity ? UNLIMITED : { limit }); } finally { fileClose.sync(io, file); }
  },
});

const dirWriteFile = quansync(function* (io, dir, path, data, flags) {
  const file = yield* dirOpenFile(io, dir, path, createFlags(flags));
  try {
    yield* fileWriteAll(io, file, data);
  } finally {
    yield* fileClose(io, file);
  }
}, {
  sync(io, dir, path, data, flags) {
    const file = dirOpenFile.sync(io, dir, path, createFlags(flags));
    try { fileWriteAll.sync(io, file, data); } finally { fileClose.sync(io, file); }
  },
});

const fileReadPositionalAll = quansync(function* (io, file, buffer, offset) {
  let total = 0;
  while (total < buffer.length) {
    const count = yield* filePread(io, file, buffer.subarray(total), offset + total);
    if (count === 0) break;
    total += count;
  }
  return total;
});

class DirImpl {
  constructor(fs, id) {
    this.kind = 'dir';
    this.fs = fs;
    this.id = id;
    freeze(this);
  }
  /// Zig `Dir.openFile`. options: `{ mode: 'read_only' | 'write_only' | 'read_write' }`.
  openFile(io, path, options) { return dirOpenFile[io.kind](io, this, path, openFlags(options)); }
  /// Zig `Dir.createFile`. options: `{ read = false, truncate = true, exclusive = false }`.
  createFile(io, path, options) { return dirOpenFile[io.kind](io, this, path, createFlags(options)); }
  openDir(io, path) { return dirOpenDir[io.kind](io, this, path); }
  close(io) { return dirClose[io.kind](io, this); }
  createDir(io, path) { return dirCreateDir[io.kind](io, this, path); }
  createDirPath(io, path) { return dirCreateDirPath[io.kind](io, this, path); }
  /// Zig `Dir.createDirPathOpen`.
  createDirPathOpen(io, path) { return dirCreateDirPathOpen[io.kind](io, this, path); }
  deleteFile(io, path) { return dirDeleteFile[io.kind](io, this, path); }
  deleteDir(io, path) { return dirDeleteDir[io.kind](io, this, path); }
  deleteTree(io, path) { return dirDeleteTree[io.kind](io, this, path); }
  /// Zig `Dir.rename(old_dir, old_sub_path, new_dir, new_sub_path, io)`, here `oldDir.rename(io, old, newDir, new)`.
  rename(io, oldPath, newDir, newPath) { return dirRename[io.kind](io, this, oldPath, newDir, newPath); }
  /// Zig `Dir.stat`: metadata of this directory.
  stat(io) { return dirStat[io.kind](io, this, ''); }
  /// Zig `Dir.statFile`: symlinks are not followed.
  statFile(io, path) { return dirStat[io.kind](io, this, path); }
  /// Zig `Dir.access`: fails with FileNotFound (etc.) when the path is not reachable.
  access(io, path) { return dirAccess[io.kind](io, this, path); }
  /// Zig `Dir.iterate` collected into an array of `{ name, kind }` (iterable).
  iterate(io) { return dirRead[io.kind](io, this); }
  /// Zig `Dir.readFileAlloc`: whole file as a Uint8Array, at most `limit` bytes.
  readFile(io, path, limit = Limit.unlimited) { return dirReadFile[io.kind](io, this, path, limit); }
  /// Zig `Dir.writeFile(io, { sub_path, data, flags })`.
  writeFile(io, { sub_path, data, flags } = {}) { return dirWriteFile[io.kind](io, this, sub_path, data, flags); }
}

class FileImpl {
  constructor(fs, id) {
    this.kind = 'file';
    this.fs = fs;
    this.id = id;
    freeze(this);
  }
  close(io) { return fileClose[io.kind](io, this); }
  stat(io) { return fileStat[io.kind](io, this); }
  length(io) { return fileLength[io.kind](io, this); }
  /// Zig `File.readStreaming` into one buffer: returns the byte count, 0 at end.
  readStreaming(io, buffer) { return fileRead[io.kind](io, this, buffer); }
  readPositional(io, buffer, offset) { return filePread[io.kind](io, this, buffer, offset); }
  /// Zig `File.readPositionalAll`: fills `buffer` from `offset` until full or end; returns the count.
  readPositionalAll(io, buffer, offset) { return fileReadPositionalAll[io.kind](io, this, buffer, offset); }
  /// Everything from the current position, at most `limit` bytes (`Limit` semantics).
  readAll(io, limit = Limit.unlimited) { return fileReadAll[io.kind](io, this, limit === Infinity ? UNLIMITED : { limit }); }
  /// Zig `File.writeStreaming` of one slice: returns the byte count (may be partial).
  writeStreaming(io, bytes) { return fileWrite[io.kind](io, this, bytes); }
  writeStreamingAll(io, bytes) { return fileWriteAll[io.kind](io, this, bytes); }
  writePositionalAll(io, bytes, offset) { return filePwriteAll[io.kind](io, this, bytes, offset); }
  setLength(io, length) { return fileSetLength[io.kind](io, this, length); }
  sync(io) { return fileSync[io.kind](io, this); }
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

/// The quansync operations behind the methods, for composing in other std modules:
/// `yield* ops.openFile(io, dir, path, flags)` inside a quansync generator, or
/// `ops.openFile[io.kind](io, dir, path, flags)` directly. `flags` are the raw
/// glue flags (`{ mode: 'read' | 'write' | 'readwrite', create, truncate, exclusive }`).
export const ops = freeze({
  openFile: dirOpenFile, openDir: dirOpenDir, closeDir: dirClose, stat: dirStat, access: dirAccess,
  createDir: dirCreateDir, createDirPath: dirCreateDirPath, createDirPathOpen: dirCreateDirPathOpen,
  deleteFile: dirDeleteFile, deleteDir: dirDeleteDir, deleteTree: dirDeleteTree, rename: dirRename,
  readDir: dirRead, readFile: dirReadFile, writeFile: dirWriteFile,
  fileClose, fileStat, fileLength, fileRead, filePread, fileReadAll, fileWrite, fileWriteAll,
  filePwriteAll, fileSetLength, fileSync, fileReadPositionalAll,
});
