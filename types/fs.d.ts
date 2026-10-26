import type { HostError, IoError } from "./errors.d.ts";
import type { Io } from "./io.d.ts";

/** The access a grant gives: read (`'r'`), write (`'w'`) or both (`'rw'`). Required, never defaulted or downgraded. */
export type Access = "r" | "w" | "rw";

/**
 * The kinds of directory entry and file (`FileKind` of `origine:@std/io`): `1` file, `2` directory,
 * `3` symlink, `4` other.
 */
export type FileKindValue = 1 | 2 | 3 | 4;

/** What a `stat` reports. */
export interface Stat {
  readonly kind: FileKindValue;
  /** Size in bytes. */
  readonly size: number;
}

/** One entry of a directory listing. */
export interface DirEntryData {
  readonly name: string;
  readonly kind: FileKindValue;
}

/**
 * The raw open mode strings of the fs operations (Python-style, plus Rust-style `c` and `t`):
 * `r` read only (the default); `rw`/`r+` read and write an existing file; `w`/`w+` create or
 * truncate; `x`/`x+` create, failing when it exists; `c`/`c+` create keeping the contents; `t`/`t+`
 * truncate without creating. Writable handles are always readable natively.
 */
export type OpenFlags = "r" | "rw" | "r+" | "w" | "w+" | "x" | "x+" | "c" | "c+" | "t" | "t+";

/** A directory descriptor of one grant: frozen `{ kind: 'dir', fs, id }`. It confers no authority by itself. */
export interface DirHandle {
  readonly kind: "dir";
  /** Id of the grant it belongs to (`0` for the `Dir.cwd()` sentinel). */
  readonly fs: number;
  readonly id: number;
}

/** A file descriptor of one grant: frozen `{ kind: 'file', fs, id }`. It confers no authority by itself. */
export interface FileHandle {
  readonly kind: "file";
  readonly fs: number;
  readonly id: number;
}

/** A view over bytes: what zero-copy reads and moving writes take. */
export type Bytes = Uint8Array;

/** Result of the zero-copy reads: `buffer` is the view to use afterwards (the one you passed is detached). */
export interface ReadInto<V extends ArrayBuffer | ArrayBufferView = ArrayBuffer | ArrayBufferView> {
  /** Bytes read; `0` at end of file. */
  readonly bytes: number;
  /** A view of the same kind, byte offset and length as the argument, over the filled memory. */
  readonly buffer: V;
}

/** An operation that has the same shape in both grants: its `args` and its result. */
interface Shared {
  dirOpenFile: [[dir: DirHandle, path: string, flags?: OpenFlags], FileHandle];
  dirOpenDir: [[dir: DirHandle, path: string], DirHandle];
  dirClose: [[dir: DirHandle], void];
  dirStat: [[dir: DirHandle, path: string], Stat];
  dirSymlinkStat: [[dir: DirHandle, path: string], Stat];
  dirRead: [[dir: DirHandle], readonly DirEntryData[]];
  dirCreateDir: [[dir: DirHandle, path: string], void];
  dirCreateDirPath: [[dir: DirHandle, path: string], void];
  dirDeleteFile: [[dir: DirHandle, path: string], void];
  dirDeleteDir: [[dir: DirHandle, path: string], void];
  dirDeleteTree: [[dir: DirHandle, path: string], void];
  dirRename: [[dir: DirHandle, oldPath: string, newDir: DirHandle, newPath: string], void];
  fileClose: [[file: FileHandle], void];
  fileStat: [[file: FileHandle], Stat];
  fileReadAll: [[file: FileHandle, options?: { readonly limit?: number }], Uint8Array];
  fileRead: [[file: FileHandle, buffer: Uint8Array], number];
  filePread: [[file: FileHandle, buffer: Uint8Array, offset: number], number];
  fileWrite: [[file: FileHandle, bytes: Uint8Array], number];
  fileWriteAll: [[file: FileHandle, bytes: Uint8Array], void];
  filePwriteAll: [[file: FileHandle, bytes: Uint8Array, offset: number], void];
  fileSetLength: [[file: FileHandle, length: number], void];
  fileSync: [[file: FileHandle], void];
}

/** Operations only the async grant implements for real (zero-copy reads and moving writes). */
interface AsyncOnly {
  fileReadInto: [[file: FileHandle, view: ArrayBuffer | ArrayBufferView], ReadInto];
  filePreadInto: [[file: FileHandle, view: ArrayBuffer | ArrayBufferView, offset: number], ReadInto];
  fileReadAlloc: [[file: FileHandle, length: number], Uint8Array];
  filePreadAlloc: [[file: FileHandle, length: number, offset: number], Uint8Array];
}

/** The moving writes: async only too, but a sync grant has them and fails `Unsupported`. */
interface Moving {
  fileWriteMove: [[file: FileHandle, bytes: Uint8Array], number];
  fileWriteMoveAll: [[file: FileHandle, bytes: Uint8Array], void];
  filePwriteMoveAll: [[file: FileHandle, bytes: Uint8Array, offset: number], void];
}

type Fn<T extends [unknown[], unknown], R> = (...args: T[0]) => R;

/**
 * The operations of a sync grant, used through `origine:@std/io` and `origine:@std/fs` rather than
 * directly. They **do not throw**: a failure is a non-zero code left in `errno[0]` and `undefined`
 * returned (`IoError.check(fs, value)` turns that into a throw). Each call re-checks the grant.
 */
export type SyncFsOps = { readonly [K in keyof Shared]: Fn<Shared[K], Shared[K][1] | undefined> } & {
  readonly [K in keyof Moving]: Fn<Moving[K], undefined>;
};

/**
 * The operations of an async grant, used through `origine:@std/io` and `origine:@std/fs` rather
 * than directly. Each returns a promise that rejects with an {@link IoError} (or a {@link HostError}: `BadHandle`, `StaleHandle`, `Canceled`).
 */
export type AsyncFsOps = { readonly [K in keyof Shared]: Fn<Shared[K], Promise<Shared[K][1]>> } & {
  readonly [K in keyof AsyncOnly]: Fn<AsyncOnly[K], Promise<AsyncOnly[K][1]>>;
} & { readonly [K in keyof Moving]: Fn<Moving[K], Promise<Moving[K][1]>> };

/** A blocking grant from `api.fs.requestSync`: operations run on the isolate thread. */
export interface SyncFs extends SyncFsOps {
  readonly kind: "sync";
  /** Id of the grant. */
  readonly id: number;
  /** Where failed operations leave their code (`errno[0]`), shared by the whole scope. */
  readonly errno: Uint32Array;
}

/** A genuinely asynchronous grant from `api.fs.requestAsync`: operations run on the `io` it was requested with. */
export interface AsyncFs extends AsyncFsOps {
  readonly kind: "async";
  /** Id of the grant. */
  readonly id: number;
}

/** Either grant: the `io` argument of the `origine:@std/io` methods. */
export type Fs = SyncFs | AsyncFs;

/** What a request names. */
export interface FsRequest {
  /** What the grant may do. Required: a missing or unknown value is `InvalidInput`; above the host's ceiling it is `PermissionDenied`. */
  readonly access: Access;
  /** A directory below the host's root to confine the grant to (lexically: no `..`, no absolute path). */
  readonly root?: string;
}

/** An async request also names the runtime its operations run on. */
export interface AsyncFsRequest extends FsRequest {
  /** A live runtime of this scope made by `api.io.create()`; a missing, closed or foreign one is `BadHandle`. */
  readonly io: Io;
}

/**
 * `api.fs`: request a grant, then use it through `origine:@std/fs` (Rust-style) or
 * `origine:@std/io` (Zig-style). There is no `narrow`: the host's ceiling and each request's
 * `access` are the only limits, and a request above the ceiling fails rather than being downgraded.
 */
export interface FsCap {
  /** A blocking grant. Throws an {@link IoError}: `PermissionDenied` (denied or sync not allowed), `InvalidInput` (missing or unknown `access`, bad `root`). */
  requestSync(request: FsRequest): SyncFs;
  /** An async grant. Rejects `BadHandle` (bad `io`), `PermissionDenied`, `InvalidInput`, or the native's failure. */
  requestAsync(request: AsyncFsRequest): Promise<AsyncFs>;
}
