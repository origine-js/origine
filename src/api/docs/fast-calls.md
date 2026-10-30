# V8 fast API calls for natives

Implementation: `fast*`, `isFast`, `Fast` and `function` in [binding.zig](../binding.zig).
Tests: "binding: hot natives take V8's fast API path" in [api.zig](../../tests/managed/api.zig), and [value/object argument tests](../../tests/managed/fast_values.zig).
Background: [Node's guide to adding V8 fast APIs](https://github.com/nodejs/node/blob/main/doc/contributing/adding-v8-fast-api.md).

A native written for `binding.object` / `binding.native` gets a V8 *fast API* entry
automatically when its signature allows it, unless it is declared
`func(f, .{ .side_effect = ..., .nofast = true })` (or `.nofast(true)` in builder style). Once TurboFan optimizes a JS caller, V8 calls
the Zig function directly with raw C arguments instead of building a
`FunctionCallbackInfo`. You write nothing extra.

## When a native is fast

All of these must hold (`isFast`):

- The first parameter is the state pointer, as for every native.
- Every other parameter is `u32`, `f64`, `bool`, `v8.Value`, or `v8.Object`, and
  there are at most 6 of them. Values and objects use V8's `kV8Value` argument ABI.
  A `*Call` parameter, strings, byte slices, `?T`, other `v8.*` handles and custom
  `decode` types are slow-path only: the fast path has no `FunctionCallbackInfo`.
- The result is `void`, `bool`, `u32`, `u64` or `f64`, or an error union of one of those.

Anything else is a plain `v8.Function`, unchanged. Handle-valued results remain
slow-path only even when their arguments are fast eligible. Passing an object does
not automatically make an operation involving strings or custom decoders fast.
Filesystem close/sync callbacks consume scalar reference IDs and can take the fast
entry; filesystem functions with Path/Bytes decoders still use the slow callback.

`i32`, `i64` and `f32` are not offered: the binding layer has no decoder for them yet, so
adding them to `fastParam`/`fastResult` also means adding `decode`/`encode` support.

## Behavior differences to know about

- **Errors.** The error is recorded in the errno cell exactly as on the slow path, but the
  call returns `0`/`false` instead of `undefined`. The guest reads the cell, not the value.
- **Cell clearing.** The cell is cleared on entry, as on the slow path.
- **Value/object validation.** `v8.Value` accepts any JavaScript value. V8's
  `kV8Value` does not check an object type or a resource brand: the binding checks
  `v8.Object` arguments with `isObject()` before wrapping them, matching the slow
  decoder. A mismatch records `InvalidInput` and returns the fast neutral result
  without invoking the callee. The callee or trusted JS wrapper still checks any
  resource identity; ownership and liveness remain the native operation's job.
- **Cold calls.** Interpreted and baseline code always use the slow callback. The fast
  entry runs only in optimized code, and V8 deoptimizes back to the slow callback when
  argument types do not match the signature.
- **Side effects and constructors.** Every native states its `side_effect` (`.none`,
  `.receiver`, `.any`) in its `func` wrapper; it is passed to V8 as the function's side-effect
  type. Fast calls are not allowed on constructors, so `constructor = .allow` also keeps a
  native on the slow path; the default is `.throw`.

## How it is wired

`function(env, State, state, func)` builds a `FunctionTemplate` with `native(State, func)`
as the slow callback and `Fast(State, func).overloads` as the C overloads.

- **State.** A fast call receives only the template's `data`, not the `FunctionCallbackInfo`.
  So fast functions store the state pointer as a **Number** (the address as an `f64`) in the
  template data. (An `External` was not tried on the fast path once the Number version
  worked.) `statePointer` reads either form, so the slow callback works for both.
- **Signature.** `CFunctionInfo` lists receiver (`V8Value`), the JS arguments, then a trailing
  `CallbackOptions`; the C function is `fn(receiver, args..., *const FastApiCallbackOptions)`.
  `FastApiCallbackOptions.data` carries the template data. Value/object arguments
  arrive as raw `usize` Local bits and are normalized through `v8.fromRawLocal`;
  this handles direct-handle Smi zero as well as indirect-handle builds.
- **Local lifetime.** Entries taking value/object arguments establish a HandleScope
  for decoding and the callee's V8 API work. Argument handles are borrowed only
  through return, with no implicit copy, detach, or retained resource. A callee
  must explicitly retain/root a value if it needs it after the call. The binding
  does not expose a scope to the callee; it simply releases temporary locals when
  the call returns. This does not permit retaining a raw buffer pointer across
  allocation, GC, reentry, or async work without the appropriate lifetime protocol.
- **Lifetime.** V8 keeps *pointers* to the `CFunction` array and its `CFunctionInfo`, and
  does not copy them. They must be static: `Fast(...)` puts all of it in comptime constants.
  Passing a stack array crashes V8 later, inside `GetFastApiCallTarget`.
- **Flag.** `--turbo-fast-api-calls` is off by default in V8; `V8.initialize` enables it.
- **Type values.** `CTypeInfo.type` numbers count from zero (`Void = 0`) as in V8's
  `v8-fast-api-calls.h`; `CallbackOptions` is 255.

## Testing a fast path

Calling in a loop is not a reliable way to get optimized code. The test harness sets
`--allow-natives-syntax` (`src/tests/support.zig`) so a test can force it:

```js
const f = (x) => native.failing(x);
%PrepareFunctionForOptimization(f);
f(false); f(false);
%OptimizeFunctionOnNextCall(f);
f(true) === 0   // fast path: error yields 0; the slow path would give undefined
```

Call the native through a function (not inline in the test's top-level script) so TurboFan
has something to optimize. Return values that differ between the two paths (like the
error case above) are how a test proves which path ran.

## API guideline check

The existing typed-native names, options, defaults, result shapes and errno meanings
are unchanged. Value/object argument signatures now receive an optimized entry in
addition to the equivalent slow callback. Arguments are borrowed, never implicitly
copied or retained; local handles created during the fast call are scoped until
return. There is no new public construction or validation API. Invalid object
arguments produce `InvalidInput`; native resource checks keep their existing
failure meanings.
