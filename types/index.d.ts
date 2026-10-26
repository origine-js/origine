// `@origine/types`: declarations for origine programs. See README.md.
//
// Importing this file (or listing the package in `types`) also declares the ambient modules
// `origine:@std/errno|io|fs|text|quansync|transformer/oxc` and the global `print`.
/// <reference path="./globals.d.ts" />
/// <reference path="./std/errno.d.ts" />
/// <reference path="./std/io.d.ts" />
/// <reference path="./std/fs.d.ts" />
/// <reference path="./std/text.d.ts" />
/// <reference path="./std/quansync.d.ts" />
/// <reference path="./std/transformer-oxc.d.ts" />

export type { Api, BasicApi, Main } from "./api.d.ts";
export type {
  ErrnoTable,
  HostError,
  HostErrorByCode,
  HostErrorOf,
  HostErrnoCode,
  HostErrnoName,
  HostErrnoTable,
  IoError,
  IoErrorByCode,
  IoErrorOf,
  IoErrnoCode,
  IoErrnoName,
  IoErrnoTable,
} from "./errors.d.ts";
export type { EnvCap, EnvNarrow } from "./env.d.ts";
export type {
  Access,
  AsyncFs,
  AsyncFsOps,
  AsyncFsRequest,
  DirEntryData,
  DirHandle,
  FileHandle,
  FileKindValue,
  Fs,
  FsCap,
  FsRequest,
  OpenFlags,
  ReadInto,
  Stat,
  SyncFs,
  SyncFsOps,
} from "./fs.d.ts";
export type { Backend, Io, IoCap, IoNarrow, IoOptions, Timer } from "./io.d.ts";
export type {
  AddressOptions,
  BytesLike,
  ConnectOptions,
  DataEvent,
  DirectWriter,
  EndSide,
  EventServer,
  EventSocket,
  Handle,
  Lease,
  ListenOptions,
  Mode,
  NetCap,
  PullServer,
  PullSocket,
  Registration,
  SendQueue,
  Server,
  ServerEvents,
  Socket,
  SocketEvents,
} from "./net.d.ts";
export type {
  HostTransformer,
  ImportMap,
  Loader,
  LoaderResult,
  Preload,
  ScopeCap,
  ScopeHandle,
  ScopeOptions,
  SourceTransform,
  Transformers,
} from "./scope.d.ts";
