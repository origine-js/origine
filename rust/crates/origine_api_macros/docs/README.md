# origine_api_macros

Proc-macro crate for [`origine_api`](../../origine_api/docs/README.md): `#[native(...)]`,
`#[derive(FromJs)]`, `#[derive(IntoJs)]`. It depends on `origine_api_core` (for `camel_case`),
`syn`, `quote`, `proc-macro2`. The generated code refers to `::origine_api::...`, so users need the
crate named `origine_api` in scope (`origine_api` itself has `extern crate self as origine_api;`).
The expansion functions work on `proc_macro2` token streams and are unit-tested in the crate
(`src/native.rs`, `src/derive.rs`; runnable under Miri).

## `#[native(...)]`

```rust
#[native(side_effect = "any", export)]
fn io_create(host: &mut HostState, key: ScopeKey, opts: Option<IoCreateOpts>) -> Result<IoHandle, NativeError> { .. }

#[native(side_effect = "any", promise, export)]
fn fs_async_open_file(host: &mut HostState, key: ScopeKey, dir: DirRef, path: String, bits: u32)
    -> Result<Op<'static, impl Future<Output = Result<u32, NativeError>> + use<>>, NativeError> { .. }
```

### Attribute options

| Option | Meaning |
|---|---|
| `side_effect = "none" \| "receiver" \| "any"` | **required**, no default (compile error otherwise). Maps to `SideEffect::{None, Receiver, Any}`, which Zig's `binding.raw` hands to V8. |
| `promise` | the fn returns a future (or `Op`, see below) and the native returns a `Promise`. Required for `async fn`. |
| `path = "namespace.name"` | **required**. Where the guest finds the native (`native.<namespace>.<name>`), exactly one dot. |
| `needs = "runtime" \| "async_fs"` | optional. Install only when the embedder configured an io runtime / async fs (default: always). |

Any other option is an error ("expected `side_effect = \"...\"`, `path = \"...\"`, `needs = \"...\"` or `promise`").

### Generated items (for fn `name`)

* the original fn, unchanged;
* `<vis> unsafe extern "C" fn <name>_raw(info: *const v8::FunctionCallbackInfo)`: the V8
  callback. It calls `native::run_sync(info, |scope, args| ...)`, which sets up a `CallbackScope`,
  runs the body under `catch_unwind`, sets the return value or throws the `NativeError`, and turns
  a panic into a thrown `Error("internal error in a native function")` (never an unwind into C++);
* `pub(crate) const NATIVE_<NAME>: RawNative = RawNative { callback: <name>_raw, side_effect, path, needs }`
  (uppercased fn name), listed in `NATIVES` (`origine_api/src/registry.rs`) so Zig installs it.

The doc comments of generated unsafe fns carry the `# Safety` section required by the workspace
lints.

### Parameters

Parameters are classified by type, and "special" ones must come **before** all JS arguments:

| Parameter type | Supplied from |
|---|---|
| `&HostState` / `&mut HostState` | the isolate's slot (`native::host_ref` / `host_mut`); at most one |
| `&mut v8::PinScope<..>` / `&mut v8::HandleScope<..>` | the callback scope |
| `ScopeKey` | which guest scope called (the callback's External data); at most one; not a JS argument |
| anything else | decoded from the next JS argument(s) with `FromJs::from_args`, left to right |

A host-state parameter and a scope parameter cannot both be used in one native in practice (the
macro would borrow the scope twice); natives that need both take the scope and fetch the state with
`host_mut(scope)` where needed. Lifetime parameters on the fn (`fn f<'s>(..)`) are allowed; named
lifetimes inside argument types are rewritten to `'_` in the generated callback.

### Argument decoding (`FromJs`)

Strict: no JS coercion; a wrong type is `TypeError("argument N: expected X")` (N = 0-based JS
argument index; a two-argument type reports the offending position).

| Rust type | JS | Rule |
|---|---|---|
| `u32` | number | integer in `0..=4294967295` |
| `u64` | number | integer in `0..=2^53-1` |
| `f64` | number | any number |
| `bool` | boolean | |
| `String` | string | copied (lossy UTF-8) |
| `Option<T>` | `T` or `null`/`undefined` | consumes `T::ARITY` arguments |
| `Vec<u8>` | `ArrayBuffer` or any view | copies the covered bytes |
| `ArrayBufferArg<'s>` | `ArrayBuffer` or view | handle + offset/len, no copy ([origine_api README](../../origine_api/docs/README.md#buffers-and-copy-semantics)) |
| `v8::Local<Object / Function / ArrayBuffer / Array / Value>` | | type check only |
| `Backend` | `"auto" \| "uring" \| "kqueue" \| "threaded"` | |
| `Handle` (`DirRef`, `FileRef`) | **two** arguments `fs, id` | each a `u32`; `ARITY = 2` |
| `Limit` | non-negative number or `Infinity` | `std.Io.Limit` semantics |
| a `derive(FromJs)` struct | object | see below |

Implement `FromJs` (with `ARITY` and optionally `from_args`) for new types. The shared range rules
are in `origine_api_core::arg`.

### Return values (`IntoJs`)

Sync natives return a type implementing `IntoJs`; `Result<T, E>` with `E: Into<NativeError>`
throws on `Err`. Provided: `()` (undefined), `bool`, `u32`, `i32`, `f64`, `u64`/`usize` (`RangeError`
above 2^53-1), `&str`/`String`, `Vec<u8>` (a `Uint8Array` over a copy in V8 memory),
`v8::Local<T>`, `Option<T>` (None = undefined), `origine_api_fs::Stat` (`[kind, size]`),
`DirListing` (flat `[name, kind, ...]`), and `derive(IntoJs)` structs.

`promise` natives return `impl IntoOp`: an `Op` or `Result<Op, E>`. `Op::new(runtime, future)`
spawns `future` on runtime `runtime`, whose output must be `Result<T, E>` (`T: IntoJs`,
`E: Into<NativeError>`); the result resolves or rejects the promise when `origine_api_poll`
settles it. An error returned from the native itself, an unknown or closed runtime, or a bad
argument yields an already-rejected promise. A panic in the future rejects with `Unexpected`.
Errors become values via `native::error_value`: `NativeError::Arg`/`Type` -> `TypeError`,
`Range` -> `RangeError`, `Error` -> `Error`, `Errno(code)` -> frozen `{ errno, name }`.

## `#[derive(FromJs)]` / `#[derive(IntoJs)]`

For plain structs with named fields and no generics.

```rust
#[derive(origine_api::FromJs)]
pub struct IoCreateOpts {
    backend: Option<Backend>,                // property "backend"
    #[js(name = "queueDepth")] entries: Option<u32>,   // explicit name instead of "entries"
    max_runtimes: Option<u32>,               // property "maxRuntimes" (camelCase)
}

#[derive(origine_api::IntoJs)]
pub struct IoHandle { kind: &'static str, id: u32, backend: &'static str }
```

* Property name: `#[js(name = "...")]` or the camelCase of the field (`max_runtimes` ->
  `maxRuntimes`; a raw-identifier `r#type` -> `type`). The `js` attribute accepts only `name`.
* `FromJs` reads **own data properties only** (accessors and inherited properties read as
  `undefined`; a missing key is `undefined`), so `Option<T>` fields are optional and other fields
  fail with `TypeError: argument N: expected property `x` to be <expected>` (nested bags:
  ``property `a.b` ...``). Unknown keys are ignored. The value itself must be an object
  (`expected an object`).
* `IntoJs` builds a plain object with `create_data_property` for each field in order and
  **freezes** it.
* Field types must implement `FromJs` / `IntoJs` respectively.

## Compile-time rejections

`#[native]`:

| Error message (abridged) | Cause |
|---|---|
| `#[native] needs an explicit side_effect` | missing option |
| `side_effect must be "none", "receiver" or "any"` / `must be a string` | bad value |
| `expected side_effect = "...", promise or export` | unknown option |
| `a #[native] fn cannot be generic (lifetime parameters are fine)` | type/const generics or a `where` clause |
| `a #[native] fn must be a plain fn` | `const`, `unsafe`, `extern "ABI"` or variadic fn |
| `an async #[native] fn needs the promise option` | `async fn` without `promise` |
| `a promise native returns a future` | `promise` with no return type |
| `a #[native] fn cannot take self` | method receivers |
| `the host state, scope and key parameters must come before the JS arguments` | ordering |
| `a #[native] fn takes at most one host state and one key parameter` | duplicates |

Derives: `FromJs/IntoJs structs cannot be generic`, `need a struct with named fields` (tuple/unit
structs), `can only be derived for structs` (enums, unions), and `expected name = "..."` for any
`#[js(...)]` key other than `name`.

## Example: a complete sync native

```rust
use origine_api::{FromJs, IntoJs, NativeError, native};

#[derive(FromJs)]
struct AddOpts { scale: Option<u32> }

#[derive(IntoJs)]
struct Sum { total: u64 }

#[native(side_effect = "none", path = "demo.addAll")]
fn add_all(a: u32, b: u32, opts: Option<AddOpts>) -> Result<Sum, NativeError> {
    let scale = opts.and_then(|o| o.scale).unwrap_or(1);
    Ok(Sum { total: (u64::from(a) + u64::from(b)) * u64::from(scale) })
}
// JS: native.demo.addAll(1, 2, { scale: 10 })  ->  frozen { total: 30 }
// Registry: one line `module::NATIVE_ADD_ALL,` in origine_api/src/registry.rs
```
