// api.fs, origine:@std/io, origine:@std/fs, origine:@std/text. Type-checked only, never run.
import type { Api, AsyncFs, HostError, IoError, SyncFs } from "@origine/types";
import { fs } from "origine:@std/fs";
import { Dir, File, FileKind, HostError as HostErrors, IoError as IoErrors, Limit, ops } from "origine:@std/io";
import { decodeUtf8, encodeUtf8, tryDecodeUtf8 } from "origine:@std/text";

type Equal<A, B> = (<T>() => T extends A ? 1 : 2) extends <T>() => T extends B ? 1 : 2 ? true : false;
const assertType = <_T extends true>() => {};

export async function main(api: Api): Promise<void> {
  const io = api.io.create();
  const sync = api.fs.requestSync({ access: "rw" });
  const readOnly = api.fs.requestSync({ access: "r", root: "data" });
  const async = await api.fs.requestAsync({ io, access: "w" });
  assertType<Equal<typeof sync, SyncFs>>();
  assertType<Equal<typeof async, AsyncFs>>();

  // --- Rust-style, sync ---------------------------------------------------------------
  const rs = fs(sync);
  rs.write("a.txt", "hello");
  rs.write("a.bin", new Uint8Array(3));
  const text: string = rs.read_to_string("a.txt");
  const bytes: Uint8Array = rs.read("a.bin");
  const entries = rs.read_dir(".");
  const name: string = entries[0]!.file_name();
  const isDir: boolean = rs.metadata(".").is_dir();
  const f = rs.File.open("a.txt");
  const count: number = f.read(new Uint8Array(8));
  f.close();
  const w = rs.OpenOptions.new().write(true).create(true).open("b.txt");
  w.write_all("x");
  w.close();
  const copied: number = rs.copy("a.txt", "c.txt");
  void [text, bytes, name, isDir, count, copied, fs(readOnly).exists("x")];

  // --- Rust-style, async: the same calls return promises ----------------------------------
  const ars = fs(async);
  const pending: Promise<string> = ars.read_to_string("a.txt");
  const file = await ars.File.create("m.txt");
  const written: number = await file.write_move(new Uint8Array(2));
  await file.write_move_all("text");
  await file.close();
  void [pending, written];

  // --- Zig-style ------------------------------------------------------------------------
  const dir = Dir.cwd();
  const opened = dir.openFile(sync, "a.txt", { mode: "read_only" });
  const all: Uint8Array = opened.readAll(sync, Limit.limited(1 << 20));
  opened.close(sync);
  const stat = dir.statFile(sync, "a.txt", { follow_symlinks: false });
  const kind: 1 | 2 | 3 | 4 = stat.kind;
  dir.writeFile(sync, { sub_path: "x", data: all, flags: { exclusive: true } });
  const afile = await dir.createFile(async, "y", { truncate: false });
  const { bytes: n, buffer } = await afile.readInto(async, new Uint8Array(8), 0);
  const view: Uint8Array = buffer;
  const alloc: Uint8Array = await afile.readAlloc(async, 16);
  await afile.writeStreamingMoveAll(async, alloc);
  void [kind, n, view, FileKind.file, File.is(afile)];

  // Errors are plain data, not Error.
  try {
    rs.read("missing");
  } catch (e) {
    if (IoErrors.is(e, IoErrors.NotFound)) {
      const known: "NotFound" = e.name;
      const code: 10 = e.errno;
      void [known, code];
    } else throw e;
    const raised: HostError = HostErrors.of(HostErrors.Canceled);
    const label: "Canceled" = raised.name;
    void label;
  }
  const code: 4 = HostErrors.Canceled;
  const named: "Io" | "NotFound" | "Unexpected" | "BrokenPipe" | "Canceled" | (string & {}) = IoErrors.name(code);
  const ioCode: IoError = IoErrors.of(IoErrors.PermissionDenied);
  void [named, ioCode, HostErrors.is({ errno: 2 }, HostErrors.BadHandle)];

  // The raw operations compose with quansync.
  const task = ops.openFile(sync, dir, "a.txt", "r");
  void task;
  const direct: Uint8Array = ops.readFile.sync(sync, dir, "a.txt", Limit.unlimited);
  void direct;

  // --- text --------------------------------------------------------------------------------
  const encoded: Uint8Array = encodeUtf8("héllo");
  const decoded: string = decodeUtf8(encoded, { fatal: true, ignoreBOM: false });
  const strict: string | null = tryDecodeUtf8(encoded);
  void [decoded, strict];

  // --- negatives -------------------------------------------------------------------------

  // @ts-expect-error `access` is required
  api.fs.requestSync({});
  // @ts-expect-error `access` is required even with a root
  api.fs.requestSync({ root: "data" });
  // @ts-expect-error not an access
  api.fs.requestSync({ access: "rwx" });
  // @ts-expect-error misspelled option key
  api.fs.requestSync({ access: "r", rot: "data" });
  // @ts-expect-error no `allowWrite`: the access says it
  api.fs.requestSync({ access: "r", allowWrite: true });
  // @ts-expect-error an async request needs the `io`
  await api.fs.requestAsync({ access: "r" });
  // @ts-expect-error the `io` of an async request is a runtime handle, not a grant
  await api.fs.requestAsync({ io: sync, access: "r" });
  // @ts-expect-error `entries` of api.io.create, not `entires`
  api.io.create({ entires: 8 });
  // @ts-expect-error a sync grant has no promise result
  await rs.read_to_string("a.txt").then(String);
  // @ts-expect-error `write_move` is async-only: not callable on a sync file
  w.write_move(new Uint8Array(1));
  // @ts-expect-error the zero-copy read is async-only
  opened.readInto(sync, new Uint8Array(8));
  // @ts-expect-error `createFile` has no `read` option
  dir.createFile(sync, "z", { read: true });
  // @ts-expect-error an unknown open mode
  dir.openFile(sync, "z", { mode: "append" });
  // @ts-expect-error `writeFile` needs `sub_path`
  dir.writeFile(sync, { data: all });
  // @ts-expect-error `io` goes first
  dir.openFile("a.txt", sync);
  // @ts-expect-error a string is not bytes for the Zig-style write
  dir.writeFile(sync, { sub_path: "x", data: "text" });
  // @ts-expect-error the builder takes the flag explicitly
  rs.OpenOptions.new().write();
  // @ts-expect-error `decodeUtf8` takes bytes, not a string
  decodeUtf8("abc");
  // @ts-expect-error misspelled decoder option
  decodeUtf8(encoded, { fatel: true });
  // @ts-expect-error an error value is not an Error
  const message: string = IoErrors.of(IoErrors.NotFound).message;
  // @ts-expect-error an unknown error code
  IoErrors.of(99);
  // @ts-expect-error a host code is not an I/O code: `of` of `IoError` takes I/O codes only
  IoErrors.of(HostErrors.BadHandle);
  // @ts-expect-error `BadHandle` is a host name, not an I/O one
  IoErrors.BadHandle;
  // @ts-expect-error `NotFound` is an I/O name, not a host one
  HostErrors.of(IoErrors.NotFound);
  // @ts-expect-error a host error value is not an I/O error value
  const wrongDomain: IoError = HostErrors.of(HostErrors.StaleHandle);
  void wrongDomain;
  void message;
}
