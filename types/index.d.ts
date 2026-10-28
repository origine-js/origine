// `@origine/types`: declarations for origine programs. See README.md.
//
// Importing this file (or listing the package in `types`) also declares the ambient modules
// `origine:@std/errno|io|fs|text|debug|quansync|transformer/oxc|graph/*`.
/// <reference path="./globals.d.ts" />
/// <reference path="./std/errno.d.ts" />
/// <reference path="./std/io.d.ts" />
/// <reference path="./std/fs.d.ts" />
/// <reference path="./std/text.d.ts" />
/// <reference path="./std/debug.d.ts" />
/// <reference path="./std/quansync.d.ts" />
/// <reference path="./std/transformer-oxc.d.ts" />
/// <reference path="./std/graph.d.ts" />

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
export type { CreateConfig, CreateOptions, Isolate, IsolateCap, IsolateExit } from "./isolate.d.ts";
export type { DataBlobOptions, Snapshot, SnapshotConstructor, SnapshotCreateOptions, SnapshotLoadOptions } from "./host.d.ts";
export type { ChannelConstructor, ChannelOptions, EventPort, HostCap, MessageEvent, Port, PortBase, PortEvents, PortMode, PullPort, SendOptions, ThreadingCap } from "./host.d.ts";
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
export type { Context, ContextCap, ContextOptions, Preload } from "./context.d.ts";
export type { GraphOptions, ModuleGraph, DerivedGraph, ModuleReference, ModuleReferenceStatus, ModuleRequest } from "./graph.d.ts";
