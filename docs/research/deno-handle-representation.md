# Deno handle representation and fast-call validation

Researched 2026-10-29 against Deno `e7b39ebd55c85aaf6a29290c1f5a99e2e21e09dd`
and deno_core `b12a3dc1c912ea91c5bc1a0da0e77e6cc28d8cf6` (the repositories' HEADs
when inspected). These are source-level findings, not performance measurements.

## JavaScript classes with private resource ids

Deno's `FsFile` is a **JavaScript class**, with `#rid`, `#readable`, and `#writable`.
`open`/`openSync` obtain a native resource id and call its constructor with a private
Symbol token. A caller lacking that token cannot construct a valid `FsFile` through
its constructor. File methods read `this.#rid` and pass the number to the actual
operation. There is no separate native `isHandle` call in this method path. Reading
`#rid` also applies JavaScript's private-field receiver check. The class additionally
stores an internal resource-id Symbol property for other bootstrap code; that is
separate from the private field. [FsFile implementation](https://github.com/denoland/deno/blob/e7b39ebd55c85aaf6a29290c1f5a99e2e21e09dd/ext/fs/30_fs.js#L642-L700).

`Conn` similarly holds a private `#rid`; `TcpConn` uses its own private `#rid` for
`setNoDelay` and `setKeepAlive`, passing it directly to the corresponding ops.
[Connection classes](https://github.com/denoland/deno/blob/e7b39ebd55c85aaf6a29290c1f5a99e2e21e09dd/ext/net/01_net.js).

This is close to the proposed JS `Handle` class design. It does **not** establish
that every Deno resource wrapper has the same constructor restriction, or that
copying Deno's numeric-id convention alone satisfies origine's grant/scope model.

## Native resource validation happens inside the operation

The TCP socket-setting ops are explicitly `#[op2(fast)]`. They accept a resource id
and a boolean, then perform `resource_table.get::<TcpStreamResource>(rid)` inside
the native operation before touching the socket. [TCP fast ops](https://github.com/denoland/deno/blob/e7b39ebd55c85aaf6a29290c1f5a99e2e21e09dd/ext/net/ops.rs#L1295-L1334).

Core synchronous read/write are also `#[op2(fast)]`: they accept a resource id and
buffer, look up the resource with `get_any`, and call its synchronous operation.
[Read/write fast ops](https://github.com/denoland/deno_core/blob/b12a3dc1c912ea91c5bc1a0da0e77e6cc28d8cf6/core/ops_builtin.rs#L407-L436).

`ResourceId` is `u32`. The per-`OpState` resource table stores `Rc<dyn Resource>` in
a map keyed by id. Typed `get<T>` both looks up and downcasts, rejecting an absent
or wrong-type resource. Taking/removing a resource means subsequent table lookup
fails; reference-counted pending users can still keep its allocation alive.
[Resource table](https://github.com/denoland/deno_core/blob/b12a3dc1c912ea91c5bc1a0da0e77e6cc28d8cf6/core/io/resource_table.rs#L11-L108),
[removal/lifetime](https://github.com/denoland/deno_core/blob/b12a3dc1c912ea91c5bc1a0da0e77e6cc28d8cf6/core/io/resource_table.rs#L119-L160).

## Value arguments and native objects are supported too

Deno_core's op2 argument table marks `v8::Local<v8::Value>`,
`v8::Local<v8::Object>`, `&v8::Value`, and `&v8::Object` as fast-call compatible.
It also supports native classes backed by Rust `GarbageCollected` types and CppGC,
with native constructors/accessors/methods. The op2 documentation demonstrates a
`#[fast]` method on such a class. A primitive-only fast-call binding policy is
therefore an embedder limitation, not a general limitation of V8/Deno.
[Op2 fastcalls, CppGC classes, argument table](https://github.com/denoland/deno_core/blob/b12a3dc1c912ea91c5bc1a0da0e77e6cc28d8cf6/ops/op2/README.md).

The compile-test suite explicitly covers `#[op2(fast)]` functions receiving
`#[cppgc] &Wrap`, including optional wrappers. Native unwrapping checks that the
argument is an API-wrapper object, unwraps its CppGC payload, and checks the Rust
`TypeId` (or supported inherited type). This is validation inside dispatch, not a
prerequisite JavaScript-to-native `is` call.
[CppGC fast-op tests](https://github.com/denoland/deno_core/blob/b12a3dc1c912ea91c5bc1a0da0e77e6cc28d8cf6/ops/op2/test_cases/sync/cppgc_resource.rs),
[CppGC unwrap checks](https://github.com/denoland/deno_core/blob/b12a3dc1c912ea91c5bc1a0da0e77e6cc28d8cf6/core/cppgc.rs#L137-L173).

CppGC pointers have lifetime rules beyond JS branding: Deno's unsafe unwrap API
returns a pointer wrapper, and its persistent/rooted variants exist for retaining
objects safely. Do not infer that an unrooted payload pointer can be retained over
arbitrary allocating JS calls or asynchronous work.
[Pointer and persistent/rooted machinery](https://github.com/denoland/deno_core/blob/b12a3dc1c912ea91c5bc1a0da0e77e6cc28d8cf6/core/cppgc.rs).

## Implication for origine (inference)

A JS class with private fields and restricted construction can perform its JS
receiver check and submit the real operation in **one** native call. Native code
must still check ownership, kind, liveness, and resource lookup in that call.
Alternatively, a value/object fast argument can carry a native wrapper and be
unwrapped/validated inside the same operation. Neither design requires a separate
`nativeIs` boundary crossing for each operation. Neither is proven faster here:
benchmark the actual optimized path, cold path, failure path, and teardown behavior.
