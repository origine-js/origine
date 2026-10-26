// `origine:@std/fs`: Rust `std::fs`-style API (snake_case) over a grant of `api.fs`.
declare module "origine:@std/fs" {
  import type { Dir, Outcome } from "origine:@std/io";

  type Fs = import("../fs.d.ts").Fs;
  type SyncFs = import("../fs.d.ts").SyncFs;
  type AsyncFs = import("../fs.d.ts").AsyncFs;

  /** Contents `write` accepts: a string (UTF-8 encoded through `origine:@std/text`) or bytes. */
  export type Contents = string | Uint8Array;

  /** An operation that exists only for async grants: on a sync grant it is not callable (it would throw `Unsupported`). */
  type AsyncOnly<F extends Fs, T> = F extends SyncFs ? never : T;

  /** `std::fs::FileType`. */
  export interface FileType {
    is_file(): boolean;
    is_dir(): boolean;
    is_symlink(): boolean;
  }

  /** `std::fs::Metadata`. */
  export interface Metadata {
    /** Size in bytes. */
    len(): number;
    is_file(): boolean;
    is_dir(): boolean;
    is_symlink(): boolean;
    file_type(): FileType;
  }

  /** `std::fs::DirEntry`. */
  export interface DirEntry {
    file_name(): string;
    file_type(): FileType;
    /** The parent path joined with the name. */
    path(): string;
  }

  /**
   * `std::fs::File`. Rust closes on drop; here **call `close()`**. Methods return the value (sync
   * grant) or a promise (async grant), and failures throw / reject an `IoError`.
   */
  export interface File<F extends Fs = Fs> {
    close(): Outcome<F, void>;
    metadata(): Outcome<F, Metadata>;
    set_len(size: number): Outcome<F, void>;
    sync_all(): Outcome<F, void>;
    sync_data(): Outcome<F, void>;
    /** Reads into `buffer` and returns the byte count, `0` at end. Copies into `buffer` when the read completes. */
    read(buffer: Uint8Array): Outcome<F, number>;
    /** Fills `buffer` completely (`InvalidData` on early end of file). */
    read_exact(buffer: Uint8Array): Outcome<F, void>;
    /** The rest of the file as bytes (there is no `Vec` out parameter). */
    read_to_end(): Outcome<F, Uint8Array>;
    /** The rest of the file as text (`InvalidData` if it is not UTF-8). */
    read_to_string(): Outcome<F, string>;
    /** Writes one slice and returns the byte count (may be partial). **Copies**: never detaches your buffer. */
    write(bytes: Contents): Outcome<F, number>;
    /** Writes everything. Copies. */
    write_all(bytes: Contents): Outcome<F, void>;
    /**
     * **Async grants only.** `write` that **transfers** `bytes`: its whole `ArrayBuffer` is detached
     * and written in place, without a copy. `Unsupported` (nothing written, buffer untouched) when
     * it cannot be detached (shared, resizable, WebAssembly memory); no silent copy. A string is encoded
     * to a fresh buffer, which is then moved.
     */
    write_move: AsyncOnly<F, (bytes: Contents) => Promise<number>>;
    /** **Async grants only.** `write_all` that transfers `bytes` (see `write_move`). */
    write_move_all: AsyncOnly<F, (bytes: Contents) => Promise<void>>;
    /** Nothing to do (writes go straight to the file): `undefined` for a sync grant, a resolved promise for an async one. */
    flush(): Outcome<F, void>;
  }

  /** `std::fs::OpenOptions`: a builder, validated as in Rust when `open` runs. `append` is `Unsupported`. */
  export interface OpenOptions<F extends Fs = Fs> {
    read(on: boolean): this;
    write(on: boolean): this;
    /** Not supported yet: `open` fails `Unsupported` when it is on. */
    append(on: boolean): this;
    /** Needs `write(true)`. */
    truncate(on: boolean): this;
    /** Needs `write(true)`. */
    create(on: boolean): this;
    /** Needs `write(true)`. Fails `AlreadyExists` if the file exists. */
    create_new(on: boolean): this;
    /** Opens `path`. Neither read nor write, or truncate/create without write, is `InvalidInput`. */
    open(path: string): Outcome<F, File<F>>;
  }

  /** What `fs(io)` returns: the Rust `std::fs` functions bound to a grant and a directory. Frozen. */
  export interface StdFs<F extends Fs = Fs> {
    /** The grant's kind: `'sync'` or `'async'`. */
    readonly kind: F["kind"];
    /** The whole file as bytes. */
    read(path: string): Outcome<F, Uint8Array>;
    /** The whole file as text; `InvalidData` if it is not UTF-8. */
    read_to_string(path: string): Outcome<F, string>;
    /** Creates or truncates `path` and writes `contents` (a string is UTF-8 encoded). Copies. */
    write(path: string, contents: Contents): Outcome<F, void>;
    /** The entries of a directory as an **array** (not lazy). */
    read_dir(path: string): Outcome<F, DirEntry[]>;
    /** Metadata, following a final symlink like `std::fs::metadata` (a dangling link is `NotFound`). */
    metadata(path: string): Outcome<F, Metadata>;
    /** Metadata of the entry itself: a final symlink is not followed. */
    symlink_metadata(path: string): Outcome<F, Metadata>;
    /** Follows symlinks (a dangling one is `false`); `false` only for `NotFound`, every other error is thrown / rejected (a loop, a denied read, a write-only grant). */
    try_exists(path: string): Outcome<F, boolean>;
    /** Like `Path::exists`: `false` on **any** error, including a denied path. Use `try_exists` to tell them apart. */
    exists(path: string): Outcome<F, boolean>;
    /** Copies a file and returns the bytes copied (64 KiB chunks). */
    copy(from: string, to: string): Outcome<F, number>;
    create_dir(path: string): Outcome<F, void>;
    create_dir_all(path: string): Outcome<F, void>;
    remove_file(path: string): Outcome<F, void>;
    /** Removes an empty directory. */
    remove_dir(path: string): Outcome<F, void>;
    remove_dir_all(path: string): Outcome<F, void>;
    rename(from: string, to: string): Outcome<F, void>;
    /** `File::open`, `create`, `create_new` and `options()`. */
    readonly File: {
      /** Opens for reading. */
      open(path: string): Outcome<F, File<F>>;
      /** Creates or truncates, for writing. */
      create(path: string): Outcome<F, File<F>>;
      /** Creates for writing, failing `AlreadyExists` if present. */
      create_new(path: string): Outcome<F, File<F>>;
      options(): OpenOptions<F>;
    };
    /** `OpenOptions::new()`. */
    readonly OpenOptions: { "new"(): OpenOptions<F> };
  }

  /**
   * Binds the Rust-style API to a grant (`api.fs.requestSync(...)` or `await api.fs.requestAsync(...)`)
   * and a directory (default `Dir.cwd()`, the grant's root). Paths are relative to `dir`. Rust's
   * `Result` maps to **throw** (sync) / **reject** (async) with an `IoError` value.
   *
   * ```ts
   * const rs = fs(api.fs.requestSync({ access: 'rw' }));
   * rs.write('a.txt', 'hello');
   * const text = rs.read_to_string('a.txt');
   * ```
   */
  export function fs<F extends Fs>(io: F, dir?: Dir): StdFs<F>;
}
