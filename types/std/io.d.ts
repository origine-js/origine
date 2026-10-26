// `origine:@std/io`: Zig-style `Dir`/`File` over a grant of `api.fs`. Holding a `Dir` or `File`
// confers no authority: the grant passed as `io` does the work and checks its access.
declare module "origine:@std/io" {
  import type { Task } from "origine:@std/quansync";

  type Fs = import("../fs.d.ts").Fs;
  type SyncFs = import("../fs.d.ts").SyncFs;
  type AsyncFs = import("../fs.d.ts").AsyncFs;
  type DirHandle = import("../fs.d.ts").DirHandle;
  type FileHandle = import("../fs.d.ts").FileHandle;
  type Stat = import("../fs.d.ts").Stat;
  type DirEntryData = import("../fs.d.ts").DirEntryData;
  type OpenFlags = import("../fs.d.ts").OpenFlags;
  type ReadInto<V extends ArrayBuffer | ArrayBufferView = ArrayBuffer | ArrayBufferView> = import("../fs.d.ts").ReadInto<V>;
  type IoErrnoTable = import("../generated/errno.d.ts").IoErrnoTable;
  type IoErrnoName = import("../generated/errno.d.ts").IoErrnoName;
  type IoErrnoCode = import("../generated/errno.d.ts").IoErrnoCode;
  type HostErrnoTable = import("../generated/errno.d.ts").HostErrnoTable;
  type HostErrnoName = import("../generated/errno.d.ts").HostErrnoName;
  type HostErrnoCode = import("../generated/errno.d.ts").HostErrnoCode;
  type ThrownIoError = import("../errors.d.ts").IoError;
  type ThrownHostError = import("../errors.d.ts").HostError;
  type IoErrorByCode<C extends IoErrnoCode> = import("../errors.d.ts").IoErrorByCode<C>;
  type HostErrorByCode<C extends HostErrnoCode> = import("../errors.d.ts").HostErrorByCode<C>;

  /**
   * What an operation returns for the grant `F`: the value for a sync grant, a promise of it for an
   * async one, either for the union.
   */
  export type Outcome<F extends Fs, T> = F extends SyncFs ? T : Promise<T>;

  /** A frozen `{ errno, name }` error value of the I/O domain: what failed fs and net operations throw or reject with. */
  export type IoError = ThrownIoError;

  /** A frozen `{ errno, name }` error value of the host domain (`BadHandle`, `StaleHandle`, `Canceled`, `Unexpected`). */
  export type HostError = ThrownHostError;

  /** The static side of {@link IoError}: the I/O error codes by name (like `ERRNO.io`) and helpers. */
  export interface IoErrorStatics extends IoErrnoTable {
    /** The name of `code`, of either domain; `'Unexpected'` for an unknown one. */
    name(code: number): IoErrnoName | HostErrnoName;
    /** Whether `value` (a code, or anything with an `errno`) is `code`. Narrows an unknown caught value to that error. */
    is(value: number, code: number): boolean;
    is<C extends IoErrnoCode>(value: unknown, code: C): value is IoErrorByCode<C>;
    /** A frozen `{ errno, name }` error value for `code`. */
    of<C extends IoErrnoCode>(code: C): IoErrorByCode<C>;
    /**
     * For a sync call: throws a frozen `{ errno, name }` (an {@link IoError} or a {@link HostError}) when
     * it left a non-zero code in `fs.errno` (and resets it), otherwise returns `value`, which a sync
     * operation returns as `undefined` only when it failed, so the result is typed without `undefined`.
     */
    check<T>(fs: { readonly errno: Uint32Array }, value: T | undefined): T;
  }

  /** The static side of {@link HostError}: the host error codes by name (like `ERRNO.host`) and helpers. */
  export interface HostErrorStatics extends HostErrnoTable {
    /** The name of `code`, of either domain; `'Unexpected'` for an unknown one. */
    name(code: number): IoErrnoName | HostErrnoName;
    /** Whether `value` (a code, or anything with an `errno`) is `code`. Narrows an unknown caught value to that error. */
    is(value: number, code: number): boolean;
    is<C extends HostErrnoCode>(value: unknown, code: C): value is HostErrorByCode<C>;
    /** A frozen `{ errno, name }` error value for `code`. */
    of<C extends HostErrnoCode>(code: C): HostErrorByCode<C>;
  }

  /**
   * I/O error codes named like Rust's `std::io::ErrorKind` (`IoError.NotFound`, ...; the set of `ERRNO.io`)
   * plus `name`, `is`, `of` and `check`. As a type, `IoError` is what a failed fs or net operation throws
   * (sync) or rejects with (async): a plain `{ errno, name }` object, not an `Error`.
   */
  export const IoError: IoErrorStatics;

  /**
   * Host error codes (`HostError.BadHandle`, ...; the set of `ERRNO.host`): origine's own runtime
   * concepts that Rust's `ErrorKind` has no name for, plus `name`, `is` and `of`. Any native can fail with one.
   */
  export const HostError: HostErrorStatics;

  /** Byte limit with `std.Io.Limit` semantics: a number, `Infinity` for no limit. */
  export type Limit = number;
  export const Limit: {
    /** No limit (`maxInt(usize)`), `Infinity`. */
    readonly unlimited: number;
    /** Nothing, `0`. */
    readonly nothing: number;
    /** At most `n` bytes. Throws `RangeError` unless `n` is a non-negative safe integer. */
    limited(n: number): number;
  };

  /** What `stat` reports as a kind. */
  export type FileKindValue = import("../fs.d.ts").FileKindValue;
  /** Kinds of entries: `{ file: 1, directory: 2, sym_link: 3, other: 4 }`. */
  export const FileKind: {
    readonly file: 1;
    readonly directory: 2;
    readonly sym_link: 3;
    readonly other: 4;
  };

  /** Options of `Dir.openFile`. */
  export interface OpenFileOptions {
    /** `'read_only'` (default), `'write_only'` or `'read_write'`. A writable handle is read/write natively; a grant with `access: 'w'` still denies reading. */
    readonly mode?: "read_only" | "write_only" | "read_write";
  }

  /** Options of `Dir.createFile` and the `flags` of `Dir.writeFile`. */
  export interface CreateFileOptions {
    /** Empty the file when it exists. Default `true`; `false` keeps its contents. */
    readonly truncate?: boolean;
    /** Fail with `AlreadyExists` when the file exists. Default `false`. */
    readonly exclusive?: boolean;
  }

  /** Options of `Dir.statFile`. */
  export interface StatFileOptions {
    /** Follow a final symlink (default `true`; a dangling one is `NotFound`). `false` is Rust's `symlink_metadata`. */
    readonly follow_symlinks?: boolean;
  }

  /** The argument of `Dir.writeFile`. */
  export interface WriteFileOptions {
    /** The path to write, relative to the directory. */
    readonly sub_path: string;
    /** The bytes (copied; never detached). */
    readonly data: Uint8Array;
    /** Whether to truncate / require a new file; the same options as `createFile`. */
    readonly flags?: CreateFileOptions;
  }

  /**
   * A directory descriptor (frozen `{ kind: 'dir', fs, id }`). Every method takes the grant `io`
   * first and returns the value (sync) or a promise of it (async). Paths are confined to the grant's
   * root lexically (no `..`, no absolute path: `PermissionDenied`; a NUL: `InvalidInput`).
   */
  export interface Dir extends DirHandle {
    /** Zig `Dir.openFile`. */
    openFile<F extends Fs>(io: F, path: string, options?: OpenFileOptions): Outcome<F, File>;
    /** Zig `Dir.createFile`: creates (and by default truncates) a file and opens it. */
    createFile<F extends Fs>(io: F, path: string, options?: CreateFileOptions): Outcome<F, File>;
    /** Opens a subdirectory. Close it with `close`. */
    openDir<F extends Fs>(io: F, path: string): Outcome<F, Dir>;
    /** Closes a descriptor opened with `openDir` or `createDirPathOpen`. */
    close<F extends Fs>(io: F): Outcome<F, void>;
    /** Creates one directory level. */
    createDir<F extends Fs>(io: F, path: string): Outcome<F, void>;
    /** Creates every missing level. */
    createDirPath<F extends Fs>(io: F, path: string): Outcome<F, void>;
    /** Zig `Dir.createDirPathOpen`: creates every level, then opens the directory. */
    createDirPathOpen<F extends Fs>(io: F, path: string): Outcome<F, Dir>;
    /** Removes a file. */
    deleteFile<F extends Fs>(io: F, path: string): Outcome<F, void>;
    /** Removes an empty directory (`DirectoryNotEmpty` otherwise). */
    deleteDir<F extends Fs>(io: F, path: string): Outcome<F, void>;
    /** Removes a whole tree. */
    deleteTree<F extends Fs>(io: F, path: string): Outcome<F, void>;
    /** Zig's `rename(old_dir, old, new_dir, new, io)` as `oldDir.rename(io, old, newDir, new)`. */
    rename<F extends Fs>(io: F, oldPath: string, newDir: DirHandle, newPath: string): Outcome<F, void>;
    /** Zig `Dir.stat`: the metadata of this directory. */
    stat<F extends Fs>(io: F): Outcome<F, Stat>;
    /** Zig `Dir.statFile`: like Rust's `fs::metadata`, a final symlink is followed unless `follow_symlinks: false`. Symlinks can lead out of the root: confinement is lexical. */
    statFile<F extends Fs>(io: F, path: string, options?: StatFileOptions): Outcome<F, Stat>;
    /** Zig `Dir.access`: resolves with no value, or fails with `NotFound` etc. (symlinks followed). */
    access<F extends Fs>(io: F, path: string): Outcome<F, void>;
    /** Zig `Dir.iterate`, collected into an array (not lazy). */
    iterate<F extends Fs>(io: F): Outcome<F, readonly DirEntryData[]>;
    /** Zig `Dir.readFileAlloc`: the whole file, at most `limit` bytes (default unlimited). */
    readFile<F extends Fs>(io: F, path: string, limit?: Limit): Outcome<F, Uint8Array>;
    /** Zig `Dir.writeFile`: creates or truncates by `flags` and writes `data`. */
    writeFile<F extends Fs>(io: F, options: WriteFileOptions): Outcome<F, void>;
  }

  /**
   * A file descriptor (frozen `{ kind: 'file', fs, id }`). Every method takes the grant `io` first.
   * **Writes copy** the bytes at call time and never detach your `ArrayBuffer`; the `*Move`
   * variants (async grants only) transfer it instead. Close with `close(io)`.
   */
  export interface File extends FileHandle {
    close<F extends Fs>(io: F): Outcome<F, void>;
    /** Flushes to storage. */
    sync<F extends Fs>(io: F): Outcome<F, void>;
    stat<F extends Fs>(io: F): Outcome<F, Stat>;
    /** The size in bytes. */
    length<F extends Fs>(io: F): Outcome<F, number>;
    /** Zig `File.readStreaming` into one buffer: the byte count, `0` at end. Copies into `buffer` at completion (do not reuse it until the promise settles). */
    readStreaming<F extends Fs>(io: F, buffer: Uint8Array): Outcome<F, number>;
    /** One positional read: the byte count, `0` at end. */
    readPositional<F extends Fs>(io: F, buffer: Uint8Array, offset: number): Outcome<F, number>;
    /** Zig `File.readPositionalAll`: fills `buffer` from `offset` until full or end; returns the count. */
    readPositionalAll<F extends Fs>(io: F, buffer: Uint8Array, offset: number): Outcome<F, number>;
    /** The rest of the file from the current position, at most `limit` bytes (default unlimited). */
    readAll<F extends Fs>(io: F, limit?: Limit): Outcome<F, Uint8Array>;
    /**
     * **Async grants only** (a sync grant throws `Unsupported`). BYOB read, zero-copy: detaches
     * `view`'s buffer (when it can: not shared, not resizable) and resolves `{ bytes, buffer }` with
     * `buffer` a view like `view` over the filled memory: use it, not `view`. Reads from `offset`
     * when given, else from the current position.
     */
    readInto<V extends ArrayBuffer | ArrayBufferView>(io: AsyncFs, view: V, offset?: number): Promise<ReadInto<V>>;
    /** **Async grants only.** Reads at most `len` bytes (from `offset`, or the current position) into host memory and resolves a `Uint8Array` of exactly the bytes read: empty at the end. */
    readAlloc(io: AsyncFs, len: number, offset?: number): Promise<Uint8Array>;
    /** Zig `File.writeStreaming` of one slice: the byte count (may be partial). Copies. */
    writeStreaming<F extends Fs>(io: F, bytes: Uint8Array): Outcome<F, number>;
    /** Writes everything. Copies. */
    writeStreamingAll<F extends Fs>(io: F, bytes: Uint8Array): Outcome<F, void>;
    /** Writes everything at `offset`. Copies. */
    writePositionalAll<F extends Fs>(io: F, bytes: Uint8Array, offset: number): Outcome<F, void>;
    /**
     * **Async grants only.** `writeStreaming` that **transfers** `bytes`: its whole `ArrayBuffer` is
     * detached (like `transfer()`, whatever the outcome) and written in place, without a copy. Fails
     * `Unsupported`, with nothing written, for a buffer that cannot be detached (shared, resizable,
     * WebAssembly memory); it never falls back to a copy. A partial write loses the rest: use
     * `writeStreamingMoveAll`.
     */
    writeStreamingMove(io: AsyncFs, bytes: Uint8Array): Promise<number>;
    /** **Async grants only.** `writeStreamingAll` that transfers `bytes` (see `writeStreamingMove`). */
    writeStreamingMoveAll(io: AsyncFs, bytes: Uint8Array): Promise<void>;
    /** **Async grants only.** `writePositionalAll` that transfers `bytes` (see `writeStreamingMove`). */
    writePositionalMoveAll(io: AsyncFs, bytes: Uint8Array, offset: number): Promise<void>;
    /** Truncates or extends the file to `length` bytes. */
    setLength<F extends Fs>(io: F, length: number): Outcome<F, void>;
  }

  /** `Dir` descriptors. Authority-free data. */
  export const Dir: {
    /** The sentinel each grant resolves to its own root. */
    cwd(): Dir;
    /** A descriptor for directory `id` of the grant `fs`. */
    at(fs: number, id: number): Dir;
    /** Whether `value` is a `Dir`. */
    is(value: unknown): value is Dir;
  };

  /** `File` descriptors. Authority-free data. */
  export const File: {
    /** A descriptor for file `id` of the grant `fs`. */
    at(fs: number, id: number): File;
    /** Whether `value` is a `File`. */
    is(value: unknown): value is File;
  };

  /** An operation of `ops`: `(io, self, ...args)`, as a task or through `.sync` / `.async`. */
  export interface Op<S extends DirHandle | FileHandle, A extends unknown[], R> {
    /** A task: `yield*` it inside a quansync composite, or `await` it (runs on an async grant). */
    (io: Fs, self: S, ...args: A): Task<R>;
    /** Runs on a sync grant: the value or a throw. */
    readonly sync: (io: SyncFs, self: S, ...args: A) => R;
    /** Runs on an async grant. */
    readonly async: (io: AsyncFs, self: S, ...args: A) => Promise<R>;
  }

  /** An operation that exists only for async grants; the sync arm throws `Unsupported`. */
  export interface AsyncOp<S extends DirHandle | FileHandle, A extends unknown[], R> {
    (io: Fs, self: S, ...args: A): Task<R>;
    /** Always throws `Unsupported`. */
    readonly sync: (io: SyncFs, self: S, ...args: A) => never;
    readonly async: (io: AsyncFs, self: S, ...args: A) => Promise<R>;
  }

  /**
   * The quansync operations behind the methods, each `(io, self, ...args)`, for composing in other
   * std modules: `yield* ops.openFile(io, dir, path, flags)` inside a quansync generator, or
   * `ops.openFile.sync(io, dir, path, flags)`. `flags` is the raw glue open mode ({@link OpenFlags}).
   * (`ops.x[io.kind]` does not type-check for a union grant: narrow `io` first or use the task form.)
   */
  export const ops: {
    readonly openFile: Op<DirHandle, [path: string, flags?: OpenFlags], File>;
    readonly openDir: Op<DirHandle, [path: string], Dir>;
    readonly closeDir: Op<DirHandle, [], void>;
    readonly stat: Op<DirHandle, [path: string], Stat>;
    readonly symlinkStat: Op<DirHandle, [path: string], Stat>;
    readonly access: Op<DirHandle, [path: string], void>;
    readonly createDir: Op<DirHandle, [path: string], void>;
    readonly createDirPath: Op<DirHandle, [path: string], void>;
    readonly createDirPathOpen: Op<DirHandle, [path: string], Dir>;
    readonly deleteFile: Op<DirHandle, [path: string], void>;
    readonly deleteDir: Op<DirHandle, [path: string], void>;
    readonly deleteTree: Op<DirHandle, [path: string], void>;
    readonly rename: Op<DirHandle, [oldPath: string, newDir: DirHandle, newPath: string], void>;
    readonly readDir: Op<DirHandle, [], readonly DirEntryData[]>;
    readonly readFile: Op<DirHandle, [path: string, limit: Limit], Uint8Array>;
    readonly writeFile: Op<DirHandle, [path: string, data: Uint8Array, flags: CreateFileOptions | undefined], void>;
    readonly fileClose: Op<FileHandle, [], void>;
    readonly fileStat: Op<FileHandle, [], Stat>;
    readonly fileLength: Op<FileHandle, [], number>;
    readonly fileRead: Op<FileHandle, [buffer: Uint8Array], number>;
    readonly filePread: Op<FileHandle, [buffer: Uint8Array, offset: number], number>;
    readonly fileReadAll: Op<FileHandle, [options?: { readonly limit?: number }], Uint8Array>;
    readonly fileReadInto: AsyncOp<FileHandle, [view: ArrayBuffer | ArrayBufferView], ReadInto>;
    readonly filePreadInto: AsyncOp<FileHandle, [view: ArrayBuffer | ArrayBufferView, offset: number], ReadInto>;
    readonly fileReadAlloc: AsyncOp<FileHandle, [length: number], Uint8Array>;
    readonly filePreadAlloc: AsyncOp<FileHandle, [length: number, offset: number], Uint8Array>;
    readonly fileWrite: Op<FileHandle, [bytes: Uint8Array], number>;
    readonly fileWriteAll: Op<FileHandle, [bytes: Uint8Array], void>;
    readonly filePwriteAll: Op<FileHandle, [bytes: Uint8Array, offset: number], void>;
    readonly fileWriteMove: AsyncOp<FileHandle, [bytes: Uint8Array], number>;
    readonly fileWriteMoveAll: AsyncOp<FileHandle, [bytes: Uint8Array], void>;
    readonly filePwriteMoveAll: AsyncOp<FileHandle, [bytes: Uint8Array, offset: number], void>;
    readonly fileSetLength: Op<FileHandle, [length: number], void>;
    readonly fileSync: Op<FileHandle, [], void>;
    readonly fileReadPositionalAll: Op<FileHandle, [buffer: Uint8Array, offset: number], number>;
  };
}
