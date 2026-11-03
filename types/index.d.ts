// `@origine/types`: declarations for origine programs. See README.md.
//
// Importing this file (or listing the package in `types`) also declares the ambient modules
// `origine:@std/errno|errors|io|fs|text|data|net|dns/presets|debug|quansync|transformer/oxc|graph/*`.
/// <reference path="./globals.d.ts" />
/// <reference path="./std/errno.d.ts" />
/// <reference path="./std/io.d.ts" />
/// <reference path="./std/errors.d.ts" />
/// <reference path="./std/fs.d.ts" />
/// <reference path="./std/text.d.ts" />
/// <reference path="./std/data.d.ts" />
/// <reference path="./std/net.d.ts" />
/// <reference path="./std/dns-presets.d.ts" />
/// <reference path="./std/debug.d.ts" />
/// <reference path="./std/quansync.d.ts" />
/// <reference path="./std/transformer-oxc.d.ts" />
/// <reference path="./std/graph.d.ts" />

export type { Api, BasicApi, Main } from './api.d.ts';
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
} from './errors.d.ts';
export type { EnvCap } from './env.d.ts';
export type { CreateConfig, CreateOptions, Isolate, IsolateCap, IsolateExit } from './isolate.d.ts';
export type { DataBlobOptions, Snapshot, SnapshotConstructor, SnapshotCreateOptions, SnapshotLoadOptions } from './host.d.ts';
export type {
  ChannelConstructor,
  ChannelOptions,
  EventPort,
  HostCap,
  MessageEvent,
  Port,
  PortBase,
  PortEvents,
  PortMode,
  PullPort,
  SendOptions,
  ThreadingCap,
} from './host.d.ts';
export type {
  Access,
  HandleMode,
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
} from './fs.d.ts';
export type { Backend, BackendChoice, Io, IoCap, IoNarrow, IoOptions, Timer } from './io.d.ts';
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
} from './net.d.ts';
export type {
  ClientAuth,
  Identity,
  RootPki,
  TlsCap,
  TlsClient,
  TlsClientOptions,
  TlsConnectOptions,
  TlsServer,
  TlsServerOptions,
  TlsInfo,
  TlsSessions,
} from './tls.d.ts';
export type {
  ClientExchange,
  ClientExchangeOf,
  ClientSession,
  ClientPool,
  FetchRequest,
  FetchResponse,
  PoolOptions,
  PoolRequestHead,
  PoolSessions,
  PoolTarget,
  RedirectRules,
  ResponseBody,
  EventClientExchange,
  EventHttpServer,
  EventServerExchange,
  EventServerSession,
  ExchangeEvents,
  HttpServerOf,
  PullClientExchange,
  PullHttpServer,
  PullServerExchange,
  PullServerSession,
  ServerExchangeOf,
  ServerSessionOf,
  HttpConnectOptions,
  Exchange,
  HeaderList,
  HttpCap,
  HttpServer,
  HttpLimits,
  RequestHead,
  ServerExchange,
  HttpServeOptions,
  ServerSession,
  Session,
  SessionOptions,
  StreamEvent,
} from './http.d.ts';
export type { DnsCap, DnsServer, Resolver, ResolverOptions } from './dns.d.ts';
export type { Context, ContextCap, ContextOptions, ContextSecurity, Preload } from './context.d.ts';
export type { GraphCap, ModuleGraph, OwnedGraph, ModuleReference, ModuleReferenceStatus, ModuleRequest } from './graph.d.ts';
