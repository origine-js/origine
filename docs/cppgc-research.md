# cppgc (CppHeap) for GC-freed native values: research

Goal: free Rust values (RootPki, TlsClient, Resolver, ...) when their JS wrapper is collected, using V8's
CppHeap instead of the `FinalizationRegistry` in `src/js/glue/tls.js:56` and `src/js/glue/dns.js:69`.
V8 sources checked: `lib/v8_zig/.lp-cache/v8-15.8.30` (the version `lib/v8_zig/justfile:23` targets).

## 1. Deno
- Deno never creates or attaches a CppHeap. `rg cpp_heap` over `libs runtime cli` finds only
  `libs/core/cppgc.rs:84` (`isolate.get_cpp_heap().unwrap()`); `libs/core/runtime/setup.rs:276-280` calls
  `v8::Isolate::new(params)` with no `cpp_heap`. It relies on V8's default heap (see 3).
- Wrapping (`libs/core/cppgc.rs`): each value is boxed as `CppGcObject<T> { tag: TypeId, member: T }`
  (`:17-33`); `make_cppgc_object` (`:70-76`) makes an instance of a `FunctionTemplate` with an empty
  constructor (`:35-46`, template stored per runtime at `libs/core/runtime/jsruntime.rs:1055-1059`),
  then `wrap_object` (`:79-98`) does `make_garbage_collected(heap, ..)` + `Object::wrap::<1, _>`. One tag
  (`CPPGC_SINGLE_TAG = 1`, `:15`) for every type; unwrap (`:143-168`) checks `is_api_wrapper()`, unwraps
  with tag 1, then compares the stored `TypeId`. Async use roots the pointer with `Persistent` (`:124-128`).
- Snapshots: the template is rebuilt at every runtime start after the isolate (and its snapshot) exist
  (`jsruntime.rs:1055`). Deno registers no API-wrapper serializer (`rg api_wrapper libs/core` is empty).
- Version: `deno_v8 0.5.0` facade over `v8 = 150.4.0` (`libs/deno_v8/Cargo.toml:40`); origine vendors
  `v8 158.0.0` (`lib/v8_zig/rusty_v8/Cargo.toml:3`). Every cppgc item Deno uses exists in the vendored
  crate with the same shape: `GarbageCollected { trace, get_name }` (`rusty_v8/src/cppgc.rs:300`),
  `make_garbage_collected` (`:353`), `UnsafePtr`, `Member`/`WeakMember`, `Persistent`/`WeakPersistent`,
  `GcCell` (`:704`), `Object::wrap/unwrap/is_api_wrapper` (`rusty_v8/src/object.rs:859-901`).

## 2. lib/v8_zig today
- Shims (`binding/rusty.cc`): `RustObj : v8::Object::Wrappable` (`binding/support.h:269`) whose destructor
  calls Rust `drop_in_place` (`rusty.cc:630`, `rusty_v8/src/cppgc.rs:108-113`); `v8__Object__Wrap/Unwrap`
  with an exact tag (`rusty.cc:640-650`); `v8__Isolate__GetCppHeap` (`:652`); `v8__CppHeap__Create` (`:662`);
  allocation (`:689`); Member/WeakMember/TracedReference tracing (`:703-716`); Persistent (`:753`).
- Rust: `Isolate::get_cpp_heap()` (`rusty_v8/src/isolate.rs:1981`) works on any isolate, including one
  made in Zig and adopted through `attach_foreign_annex` (`isolate.rs:1209`). `CreateParams::cpp_heap`
  exists (`isolate_create_params.rs:282`). `Object::unwrap` casts without a type check, so a per-type
  tag or a stored type id is the caller's job (Deno's `TypeId`).
- Zig: `Isolate.CreateParams` has `cpp_heap: ?*const anyopaque = null` (`src/v8/Isolate.zig:34`); there is
  no other cppgc surface in `lib/v8_zig/src` (none is needed if only Rust wraps).
- Missing for origine: nothing in the binding. Missing in origine_api: a wrapper template, a typed
  wrap/unwrap helper, and `#[native]` argument/return support for wrapped values.

## 3. Snapshots
- V8 always has a CppHeap: `Isolate::Initialize` creates a default one when `params.cpp_heap` is null and
  calls `ConfigureHeap` with it *before* `Snapshot::Initialize` (`src/api/api.cc:10344-10368`). A snapshot
  made by origine's SnapshotCreator also had one, so "restored without a CppHeap" does not arise.
  `cppgc::InitializeProcess` is done by `V8::Initialize` (`api.cc:6597-6602`); origine calls that in
  `src/engine.zig:28`.
- Serialization: a reachable JS API wrapper that holds a cppgc pointer needs a `SerializeAPIWrapperCallback`
  (`src/snapshot/context-serializer.cc:236-251`; with a null callback it only DCHECKs, then calls it).
  origine's `setDefaultContext` passes none (`src/managed/snapshot.zig:48`, `init_snapshot.zig:363`).
  So no wrapped object may be reachable when either snapshot is made; wrappers with no pointer are fine.
- Finalizers run on the mutator thread: the concurrent sweeper only queues finalizable pages
  (`src/heap/cppgc-internal/sweeper.cc:833-866`, `swept_unfinalized_pages`).

## 4. Recommended design (minimal)
Use the default CppHeap; do not touch Zig `CreateParams`. Do it all in origine_api, Deno-style:
1. `rust/crates/origine_api/src/gc.rs` (new): `Wrapped<T> { kind: TypeId, value: T }` implementing
   `GarbageCollected` (trace no-op for plain values); `wrap<T>(scope, T) -> Local<Object>` and
   `unwrap<T>(isolate, Local<Value>) -> Option<UnsafePtr<..>>` with one origine tag + `TypeId` check.
2. Per-isolate `Global<FunctionTemplate>` (or `ObjectTemplate`) created lazily in `HostState` on first wrap,
   never during snapshot creation; drop it in `origine_api_detach_isolate` (`src/lib.rs:91+`).
3. Natives `tls.roots/client/server/identity` and `dns.resolver` return the wrapper instead of a `u32` id;
   consumers take the wrapper and `unwrap` it; delete `tls.release`/`dns.release` (`tls.rs:216-222`,
   `dns.rs:296`) and the `FinalizationRegistry` blocks in `src/js/glue/{tls,dns}.js`. Async natives
   root the value (`Persistent`) or clone an `Arc` out before awaiting.
4. Update `rust/crates/origine_api/docs/natives.md` and follow `docs/api-guidelines.md` for the change.
Risks:
- Drop runs inside GC (any allocation point, maybe during a native that holds `&mut HostState`): the
  dropped Rust value must not touch `HostState`, V8 or the scope tables; keep it self-contained (`Arc`s)
  or push work onto a queue. Values are no longer keyed by `ScopeKey`, so scope disposal no longer frees
  them; check the capability model still holds (a wrapper is only usable in contexts that can reach it).
- Isolate teardown may finalize leftovers after `detach_foreign_annex`; same self-containment rule.
- Any wrapper reachable at snapshot time crashes snapshot creation (see 3).
- `Object::wrap` needs a JS API object (template instance); plain `Object::new` objects cannot hold it.
Not verified: whether CppHeap termination at isolate dispose runs every pending finalizer.

## 5. Why a JS wrapper class over the cppgc object? (It is gone.)
The first cut (`d284d3b`) made every native value an instance of one shared empty `FunctionTemplate` and wrapped
that opaque object in a JS class (`class RootPki { #handle }`) in `src/js/glue/tls.js` / `dns.js`.
- What the JS class bought: a class name and prototype, named static constructors, a brand check (`#handle`),
  `new X()` refused, frozen statics and prototype, docs next to the code, and errors converted to the realm's
  `IoError` by the glue's `settling` wrapper of every `native.*` function.
- What it cost: two objects per value (the JS instance and the native one), a second brand check (the `TypeId`)
  under the first, a `release()` that only dropped the JS reference, and every surface written twice (a JS
  method calling a native that repeats the argument checks).
- Everything on the first list is a property of a `FunctionTemplate`, which is what Deno does for its cppgc
  objects (`#[op2] impl` with `#[constructor]`, `#[static_method]`, `#[getter]`, `libs/core/runtime/bindings.rs`):
  a class name (`SetClassName`), a throwing constructor, statics on the template, methods and accessors on the
  prototype template, instances from the instance template (`instanceof` works), the `TypeId` unwrap as the only
  brand check. Freezing and the error class are per realm, so the installer native does both once per realm
  (`class.rs`). So the class is now defined whole in Rust (`#[class]`, `rust/crates/origine_api/docs/natives.md`).
- What stays in JS: members that need the glue's own objects (`TlsClient.connect` takes and makes `api.net`
  sockets; `Resolver.lookup` returns `IpAddr`s and `Resolver.io` the `api.io` handle) are passed to the installer,
  which defines them on the Rust prototype before freezing it. Symbol-keyed members (`Symbol.asyncDispose`) are
  glue members too: the binding has no `v8::Symbol::GetAsyncDispose`, and reading `Symbol.asyncDispose` from a
  realm's global at template time would let one realm poison an isolate-wide template.
