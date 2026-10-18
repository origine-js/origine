// `@engine/std/fs`: Rust `std::fs`-style API (snake_case) over the same grant as
// `@engine/std/io`. There is no ambient cwd, so the API is bound to an `io`
// (`fs.sync` or `fs.async`) and a directory (default `Dir.cwd()`):
//
//   const rs = fs(api_fs.sync);                // or fs(api_fs.async, someDir)
//   rs.write('a.txt', 'hello');                // sync: returns / throws an IoError value
//   const text = rs.read_to_string('a.txt');   // async: the same calls return promises
//   const f = rs.File.open('a.txt'); f.read(buf); f.close();
//   rs.OpenOptions.new().write(true).create(true).open('b.txt');
//
// Rust's `Result` maps to throw (sync) / reject (async) with `{ errno, name }`
// error values (`IoError`). All of it is written once with quansync and shares the
// Zig-style ops from `@engine/std/io`, so it costs one extra JS call per operation.
//
// Not shipped yet: canonicalize, read_link, symlink, set_permissions, hard_link,
// File::seek and append mode (no native support), and lazy ReadDir iterators
// (`read_dir` returns an array of DirEntry).
import { quansync } from '@engine/std/quansync';
import { Dir, FileKind, IoError, ops } from '@engine/std/io';
import { decodeUtf8, encodeUtf8 } from '@engine/std/text';

const freeze = Object.freeze;
const UNLIMITED = freeze({ limit: Infinity });
const COPY_CHUNK = 64 * 1024;

const fail = code => { throw IoError.of(code); };
const toBytes = contents => typeof contents === 'string' ? encodeUtf8(contents) : contents;

/// `std::fs::FileType`.
class FileType {
  #kind;
  constructor(kind) { this.#kind = kind; freeze(this); }
  is_file() { return this.#kind === FileKind.file; }
  is_dir() { return this.#kind === FileKind.directory; }
  is_symlink() { return this.#kind === FileKind.sym_link; }
}

/// `std::fs::Metadata`.
class Metadata {
  #stat;
  constructor(stat) { this.#stat = stat; freeze(this); }
  len() { return this.#stat.size; }
  is_file() { return this.#stat.kind === FileKind.file; }
  is_dir() { return this.#stat.kind === FileKind.directory; }
  is_symlink() { return this.#stat.kind === FileKind.sym_link; }
  file_type() { return new FileType(this.#stat.kind); }
}

/// `std::fs::DirEntry`.
class DirEntry {
  #parent;
  #entry;
  constructor(parent, entry) { this.#parent = parent; this.#entry = entry; freeze(this); }
  file_name() { return this.#entry.name; }
  file_type() { return new FileType(this.#entry.kind); }
  path() { return this.#parent === '' || this.#parent === '.' ? this.#entry.name : this.#parent.replace(/\/+$/, '') + '/' + this.#entry.name; }
}

// ---- operations: (ctx, ...args), ctx = { io, dir } ---------------------------

const read = quansync(function* (ctx, path) {
  return yield* ops.readFile(ctx.io, ctx.dir, path, Infinity);
}, { sync: (ctx, path) => ops.readFile.sync(ctx.io, ctx.dir, path, Infinity) });

const readToString = quansync(function* (ctx, path) {
  const text = decodeUtf8(yield* read(ctx, path));
  return text === undefined ? fail(IoError.InvalidData) : text;
}, {
  sync(ctx, path) {
    const text = decodeUtf8(ops.readFile.sync(ctx.io, ctx.dir, path, Infinity));
    return text === undefined ? fail(IoError.InvalidData) : text;
  },
});

const write = quansync(function* (ctx, path, contents) {
  return yield* ops.writeFile(ctx.io, ctx.dir, path, toBytes(contents), undefined);
}, { sync: (ctx, path, contents) => ops.writeFile.sync(ctx.io, ctx.dir, path, toBytes(contents), undefined) });

const readDir = quansync(function* (ctx, path) {
  const dir = yield* ops.openDir(ctx.io, ctx.dir, path);
  try {
    const entries = yield* ops.readDir(ctx.io, dir);
    return entries.map(entry => new DirEntry(path, entry));
  } finally {
    yield* ops.closeDir(ctx.io, dir);
  }
});

const metadata = quansync(function* (ctx, path) {
  return new Metadata(yield* ops.stat(ctx.io, ctx.dir, path));
}, { sync: (ctx, path) => new Metadata(ops.stat.sync(ctx.io, ctx.dir, path)) });

const tryExists = quansync(function* (ctx, path) {
  try {
    yield* ops.stat(ctx.io, ctx.dir, path);
    return true;
  } catch (error) {
    if (IoError.is(error, IoError.FileNotFound)) return false;
    throw error;
  }
}, {
  sync(ctx, path) {
    try {
      ops.stat.sync(ctx.io, ctx.dir, path);
      return true;
    } catch (error) {
      if (IoError.is(error, IoError.FileNotFound)) return false;
      throw error;
    }
  },
});

const exists = quansync(function* (ctx, path) {
  try {
    yield* ops.stat(ctx.io, ctx.dir, path);
    return true;
  } catch {
    return false;
  }
}, {
  sync(ctx, path) {
    try { ops.stat.sync(ctx.io, ctx.dir, path); return true; } catch { return false; }
  },
});

const copy = quansync(function* (ctx, from, to) {
  const { io, dir } = ctx;
  const source = yield* ops.openFile(io, dir, from, { mode: 'read' });
  try {
    const target = yield* ops.openFile(io, dir, to, { mode: 'write', create: true, truncate: true });
    try {
      const size = (yield* ops.fileLength(io, source)) + 1; // +1 so one read sees the end
      const buffer = new Uint8Array(Math.min(size, COPY_CHUNK));
      let total = 0;
      for (;;) {
        const count = yield* ops.fileRead(io, source, buffer);
        if (count === 0) return total;
        yield* ops.fileWriteAll(io, target, count === buffer.length ? buffer : buffer.subarray(0, count));
        total += count;
      }
    } finally {
      yield* ops.fileClose(io, target);
    }
  } finally {
    yield* ops.fileClose(io, source);
  }
});

const createDir = quansync(function* (ctx, path) { return yield* ops.createDir(ctx.io, ctx.dir, path); });
const createDirAll = quansync(function* (ctx, path) { return yield* ops.createDirPath(ctx.io, ctx.dir, path); });
const removeFile = quansync(function* (ctx, path) { return yield* ops.deleteFile(ctx.io, ctx.dir, path); });
const removeDir = quansync(function* (ctx, path) { return yield* ops.deleteDir(ctx.io, ctx.dir, path); });
const removeDirAll = quansync(function* (ctx, path) { return yield* ops.deleteTree(ctx.io, ctx.dir, path); });
const rename = quansync(function* (ctx, from, to) { return yield* ops.rename(ctx.io, ctx.dir, from, ctx.dir, to); });

// ---- File and OpenOptions -------------------------------------------------

const openWith = quansync(function* (ctx, path, flags) {
  return new FileHandle(ctx, yield* ops.openFile(ctx.io, ctx.dir, path, flags));
});

const fileReadToEnd = quansync(function* (ctx, file) { return yield* ops.fileReadAll(ctx.io, file, UNLIMITED); });
const fileReadToString = quansync(function* (ctx, file) {
  const text = decodeUtf8(yield* fileReadToEnd(ctx, file));
  return text === undefined ? fail(IoError.InvalidData) : text;
});
const fileReadExact = quansync(function* (ctx, file, buffer) {
  let filled = 0;
  while (filled < buffer.length) {
    const count = yield* ops.fileRead(ctx.io, file, buffer.subarray(filled));
    if (count === 0) return fail(IoError.InvalidData); // Rust: UnexpectedEof
    filled += count;
  }
});

/// `std::fs::File`. Rust closes on drop; here call `close()` when done.
class FileHandle {
  #ctx;
  #file;
  constructor(ctx, file) { this.#ctx = ctx; this.#file = file; freeze(this); }
  close() { return ops.fileClose[this.#ctx.io.kind](this.#ctx.io, this.#file); }
  metadata() { return fileMetadata[this.#ctx.io.kind](this.#ctx, this.#file); }
  set_len(size) { return ops.fileSetLength[this.#ctx.io.kind](this.#ctx.io, this.#file, size); }
  sync_all() { return ops.fileSync[this.#ctx.io.kind](this.#ctx.io, this.#file); }
  sync_data() { return ops.fileSync[this.#ctx.io.kind](this.#ctx.io, this.#file); }
  /// Reads into `buffer` (a Uint8Array) and returns the byte count; 0 at end.
  read(buffer) { return ops.fileRead[this.#ctx.io.kind](this.#ctx.io, this.#file, buffer); }
  read_exact(buffer) { return fileReadExact[this.#ctx.io.kind](this.#ctx, this.#file, buffer); }
  /// Returns the rest of the file as a Uint8Array (there is no `Vec` out parameter).
  read_to_end() { return fileReadToEnd[this.#ctx.io.kind](this.#ctx, this.#file); }
  read_to_string() { return fileReadToString[this.#ctx.io.kind](this.#ctx, this.#file); }
  /// Writes one slice and returns the byte count written (may be partial).
  write(bytes) { return ops.fileWrite[this.#ctx.io.kind](this.#ctx.io, this.#file, toBytes(bytes)); }
  write_all(bytes) { return ops.fileWriteAll[this.#ctx.io.kind](this.#ctx.io, this.#file, toBytes(bytes)); }
  flush() { return this.#ctx.io.kind === 'sync' ? undefined : Promise.resolve(); }
}

const fileMetadata = quansync(function* (ctx, file) { return new Metadata(yield* ops.fileStat(ctx.io, file)); });

// Validates a builder snapshot like Rust does, then opens. Errors throw/reject.
const openOptions = quansync(function* (ctx, path, spec) {
  if (spec.append) fail(IoError.Unsupported);
  if (!spec.read && !spec.write) fail(IoError.InvalidPath); // Rust: InvalidInput
  if (!spec.write && (spec.truncate || spec.create || spec.create_new)) fail(IoError.InvalidPath);
  return yield* openWith(ctx, path, {
    mode: spec.read && spec.write ? 'readwrite' : spec.write ? 'write' : 'read',
    create: spec.create || spec.create_new,
    truncate: spec.truncate,
    exclusive: spec.create_new,
  });
});

/// `std::fs::OpenOptions` builder. `append` is not supported yet.
class OpenOptionsBuilder {
  #ctx;
  #spec = { read: false, write: false, append: false, truncate: false, create: false, create_new: false };
  constructor(ctx) { this.#ctx = ctx; }
  read(on) { this.#spec.read = on; return this; }
  write(on) { this.#spec.write = on; return this; }
  append(on) { this.#spec.append = on; return this; }
  truncate(on) { this.#spec.truncate = on; return this; }
  create(on) { this.#spec.create = on; return this; }
  create_new(on) { this.#spec.create_new = on; return this; }
  open(path) { return openOptions[this.#ctx.io.kind](this.#ctx, path, { ...this.#spec }); }
}

/// Binds the Rust-style API to `io` (`fs.sync` or `fs.async` from `api.fs`) and a
/// directory. Paths are relative to `dir`, which defaults to the grant root.
export function fs(io, dir = Dir.cwd()) {
  const ctx = freeze({ io, dir });
  const kind = io.kind;
  const one = task => { const run = task[kind]; return path => run(ctx, path); };
  const two = task => { const run = task[kind]; return (a, b) => run(ctx, a, b); };
  const File = freeze({
    open: path => openWith[kind](ctx, path, { mode: 'read' }),
    create: path => openWith[kind](ctx, path, { mode: 'write', create: true, truncate: true }),
    create_new: path => openWith[kind](ctx, path, { mode: 'write', create: true, exclusive: true }),
    options: () => new OpenOptionsBuilder(ctx),
  });
  const OpenOptions = freeze({ new: () => new OpenOptionsBuilder(ctx) });
  return freeze({
    kind,
    read: one(read),
    read_to_string: one(readToString),
    write: two(write),
    read_dir: one(readDir),
    metadata: one(metadata),
    try_exists: one(tryExists),
    exists: one(exists),
    copy: two(copy),
    create_dir: one(createDir),
    create_dir_all: one(createDirAll),
    remove_file: one(removeFile),
    remove_dir: one(removeDir),
    remove_dir_all: one(removeDirAll),
    rename: two(rename),
    File,
    OpenOptions,
  });
}
