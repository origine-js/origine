# JavaScript guards before native bindings

Research date: 2026-11-02. Scope: whether generated JavaScript argument guards can improve calls into V8 native callbacks. This is source research, with no measured speedup or binding implementation change. The local V8 checkout is 15.8.30, commit `a98309795399032afd2f191adaa94ed6e9918437`. V8 compiler links below use that revision; the Node contributor guide is a moving reference.

## Conclusion

A JS guard exposes a condition V8 can optimize, but does not expose or eliminate validation inside a compiled native callback. Layering generated guards over the current checked slow callback therefore has no demonstrated happy-path benefit. Invalid argument rejection is the stronger candidate: it can avoid the native boundary and its error transport. Ordinary native operation failures, such as a missing file or stale resource, still require native execution.

For happy-path work, first measure existing Fast API coverage and the cost of argument conversion. Generate guards selectively where they preserve the public contract; do not adopt them across all bindings on the assumption that V8 will remove native checks.

## What the primary sources establish

### V8 can optimize guards it can see in its own graph

V8's optimizing compilers use runtime feedback and compiler-known facts. Its Maglev description explains that a successful shape check supplies information for later operations, allowing repeated checks to be avoided; speculative facts still require guards or invalidation dependencies. It also distinguishes optimizing tiers from interpreter/baseline execution. Consequently, warming up a monomorphic loop and running a short-lived script are different experiments. [V8: Maglev, Known Node Information and Deoptimization](https://v8.dev/blog/maglev#known-node-information)

Concrete compiler examples: `TypedOptimization::ReduceCheckNumber` and `ReduceCheckString` remove checks when the input already has the required type; `ReduceTypeOf` folds `typeof` when the type is known. These are evidence that visible guards **can** become cheap or redundant, not a guarantee that an arbitrary wrapper or call site will be inlined and optimized. [V8 typed-optimization.cc](https://github.com/v8/v8/blob/a98309795399032afd2f191adaa94ed6e9918437/src/compiler/typed-optimization.cc)

The redundancy pass also recognizes relationships such as a small-integer check subsuming a number check, and matches checks against their value inputs and effect-path history. This is compiler-local reasoning, not a mechanism for inspecting a native callback's compiled machine code. [V8 redundancy-elimination.cc, fixed revision](https://chromium.googlesource.com/v8/v8/+/a98309795399032afd2f191adaa94ed6e9918437/src/compiler/redundancy-elimination.cc)

### Ordinary callbacks and Fast API callbacks expose different contracts

The ordinary callback convention receives `FunctionCallbackInfo<Value>` and sets a V8 return value. The Fast API convention registers a `CFunction` alongside the slow callback and can pass native scalar arguments/results directly. V8 chooses the applicable path; a JavaScript guard alone does not register a fast callback. Node's contributor guide explicitly permits validation of `Local<Value>` fast arguments in a JavaScript wrapper, while requiring the implementation to validate those values somewhere. Such arguments have an `any`-like signature. [Node.js: Adding V8 Fast API callbacks](https://github.com/nodejs/node/blob/main/doc/contributing/adding-v8-fast-api.md)

In V8's `ReduceCallApiFunction`, a registered fast target produces a `FastApiCall` subgraph. Otherwise it emits a call through an API callback builtin and an external native callback address. Receiver/access checks can themselves be optimized, so “slow callback” does not mean “V8 cannot optimize anything around this call.” The callback body is still external to this JS optimization graph. **Inference:** adding a JS `typeof` test does not let V8 delete an `isNumber` test inside independently compiled Zig/Rust/C++ code. Removing that native test would require an explicit native implementation/contract change. [V8 js-call-reducer.cc, ReduceCallApiFunction](https://github.com/v8/v8/blob/a98309795399032afd2f191adaa94ed6e9918437/src/compiler/js-call-reducer.cc)

### Exceptions and Fast API capabilities are version-sensitive

The opening comment of V8's fast-call header still describes historical restrictions on allocation, re-entry, throwing, and a fallback flag. Do not use that comment alone as a current capability list. [V8 v8-fast-api-calls.h](https://chromium.googlesource.com/v8/v8/+/a98309795399032afd2f191adaa94ed6e9918437/include/v8-fast-api-calls.h)

Node's current guide says the earlier no-re-entry/no-direct-throw restrictions were lifted in V8 12.6. The current V8 lowering supports this: its call descriptor can throw, it checks the isolate's pending exception after the native call, and it propagates a pending exception. Argument adaptation failures have a separate failure result. Exact behavior still depends on the embedded version and its binding layer. [Node.js Fast API guide](https://github.com/nodejs/node/blob/main/doc/contributing/adding-v8-fast-api.md), [V8 fast-api-call-lowering-reducer.h](https://github.com/v8/v8/blob/a98309795399032afd2f191adaa94ed6e9918437/src/compiler/turboshaft/fast-api-call-lowering-reducer.h)

## Implications to test in Origine

These are hypotheses derived from the mechanisms above, not benchmark results:

- **Valid arguments, existing slow callback:** a wrapper adds a JS guard and call layer while the existing native validation remains. V8 may inline/remove the visible JS overhead in favorable cases. There is no established reason to expect a universal happy-path win from “showing V8 the type.”
- **Valid arguments, existing Fast API scalar signature:** V8 already has the native type contract. An extra JS guard may be redundant, may share information with call adaptation, or may add work; inspect generated code and measure.
- **Invalid arguments:** a wrapper can reject before crossing into native code. That can avoid native decode and binding-specific error transport. It still pays JavaScript exception construction/throw/catch costs. A speedup is plausible, not guaranteed; compare equivalent exceptions and observable behavior.
- **A deliberately unchecked native entry point:** a generated wrapper can move validation into JS, but that is a different design from layering checks over the existing callback. Every route to the entry point, including unoptimized execution, must preserve its preconditions. V8's ability to optimize a wrapper is not a safety proof for removing native checks.

Correctness requires matching the actual binding contract before timing it. Examples to audit include number-vs-integer conversion, `NaN`, infinities, `-0`, missing arguments/defaults, callable objects, all accepted view kinds, shared/resizable/detached buffers, exception class/message, and validation order. This is a proposed audit list; accepted behavior comes from local implementation and API guidelines, not these external sources.

## Useful experiment shape

Compare the current public path against an otherwise identical guarded wrapper, separately for existing fast and slow bindings. Keep normal and error cases separate. Include both cold calls and warmed loops, monomorphic and mixed inputs, literal/known and runtime-produced arguments, and calls from typical public wrappers. Consume results so the benchmark retains useful work. Report V8 version, flags, warmup, repetitions, and dispersion.

Treat optimized-code/trace inspection as evidence for the mechanism and end-to-end timing as evidence for the performance effect. Neither a tiny scalar benchmark nor a repeatedly caught exception loop establishes the benefit for file/network/text workloads. No implementation change is implied by this research.

## Findings in this repository

### Existing paths

- `binding.nativeWith` recovers state, initializes a per-call arena and `Call`, checks detached state where applicable, then invokes the typed decoder. A JS rejection can skip that setup, decoding and native error reporting. Arena initialization does not mean every call allocates heap memory. [Callback setup](../../src/api/binding.zig#L169), [Call initialization](../../src/api/call.zig#L47).
- `fastParam` already exposes `u32`, `f64`, `bool`, `v8.Value` and `v8.Object` through Fast API metadata. Eligibility also depends on result type, arity, injected parameters and binding options. `*Call`, strings, byte slices and custom decoder parameters do not qualify through this generic path. A `v8.Value`/`v8.Object` parameter uses the broad `V8Value` ABI; the latter still has an explicit object check in `Fast.run`. [Fast eligibility and entry](../../src/api/binding.zig#L263).
- `binding.function` deliberately installs only a plain callback when `env.rebind` is set for snapshot construction. It also stays slow for `.nofast`, allowed constructors and ineligible signatures. A JS guard does not change those decisions. Snapshot-safe Fast API support would be a separate project involving callback data and external references. [Function construction](../../src/api/binding.zig#L570).
- `encodeUtf8` already captures its native callback and checks `typeof text === 'string'` in JS. Its native implementation checks `value.isString()` again. Because it takes `*Call` and returns `v8.Value`, this operation does not qualify for the generic Fast API entry. This is an existing example of the proposed guarded-but-still-checked slow-call design, not evidence of a speedup. [JS wrapper](../../src/js/std/text.js#L6), [Native implementation](../../src/api/std/text.zig#L19).
- Binding argument errors become `InvalidArgument`, mapped to `InvalidInput`, with an errno write and an undefined slow-path result. The fast entry uses a zero result for failures. Public glue such as `IoError.check` reads and resets errno and constructs the public error. A generated wrapper that throws `TypeError` instead is not automatically equivalent to this path. [Decoder](../../src/api/binding.zig#L602), [Error mapping](../../src/api/errno.zig#L92), [Public error handling](../../src/js/glue/errors.js#L43), [Existing fast/slow tests](../../src/tests/managed/api.zig#L2904).

### A generator must describe decoding semantics, not just Zig types

The following details come from `decode` and `viewBytes`, rather than from the names of Zig parameter types. [Decoders](../../src/api/binding.zig#L602), [View extraction](../../src/api/binding.zig#L81).

| Native parameter | Existing behavior relevant to a JS guard |
| --- | --- |
| `u32` | Requires a JS number, then uses V8 `Uint32Value`; this converts rather than enforcing an integer in `0..2**32-1`. |
| `u64` | Requires a nonnegative integer number at most `2**53-1`; this is not a BigInt parameter. |
| `f64` | Requires a number; the decoder does not reject `NaN` or infinity. |
| `bool` | Requires a boolean, rather than JS truthiness. |
| `[]const u8` | Requires a string, then computes UTF-8 length, allocates and copies. A JS type guard does not remove those conversion costs. |
| `[]u8` | Uses `ArrayBufferView` extraction, including DataView and typed-array kinds beyond Uint8Array, with backing-store restrictions. An `instanceof Uint8Array` guard is narrower. |
| `v8.Object` | Accepts objects, including functions, and rejects null. `typeof x === 'object'` alone does not match. |
| `?T` | Accepts both undefined and null before decoding `T`. |
| Custom `decode` | May consume multiple JS positions through `arity` and perform semantic validation; its Zig type alone does not describe a matching JS predicate. |

The pinned V8 implementation confirms the `Uint32Value` number conversion via `NumberToUint32`. For example, replacing that conversion with `Number.isInteger` plus a range guard changes the accepted inputs. Audit slow/fast parity separately rather than assuming a C ABI type implies strict JS range validation. [Pinned V8 implementation](https://github.com/v8/v8/blob/a98309795399032afd2f191adaa94ed6e9918437/src/api/api.cc#L4643-L4651).

Preserve error precedence too: the existing callback can report detached state before argument decoding. Reading mutable properties, invoking coercions or user callbacks between a JS check and native use can invalidate facts about mutable state. If removing checks in a future design, prove the exact invariant for the captured argument and every route to the native entry; retain native ownership/liveness and buffer-safety checks where JS predicates do not establish them. Any changed public errors or conversions must follow [API guidelines](../api-guidelines.md).

### Minimal benchmark decision matrix

Use the same tiny native operation and error contract in each row, with a captured native target and fixed-arity wrapper. Avoid rest/spread, reflective dispatch and per-call schema iteration in the generated path; those would test a different wrapper design.

| Variant | Question answered |
| --- | --- |
| Checked slow callback, ordinary forwarding wrapper | Baseline public call overhead. |
| Same checked slow callback, added JS guards | Does the proposed additive change pay for itself? |
| Existing Fast API callback, with/without identical guards | Do guards help or duplicate existing adaptation? |
| Separate private entry with selected checks deliberately moved to JS | Does actual relocation help? Requires a correctness argument; not equivalent to merely adding guards. |

For each, time valid calls, wrong-type calls, and valid-type native failures separately. Add rare wrong-type calls after valid warmup as well as sustained invalid traffic, so deoptimization/reoptimization is visible. Keep exception construction, error fields and stack access equivalent; do not compare an errno-only return with a thrown exception. Consume a changing result and retain native side effects where appropriate. Report snapshot-created versus dynamically created bindings separately, since they currently have different registration paths. The existing tests demonstrate forced optimization and fast/slow result differences, but contain no throughput evidence. [Binding tests](../../src/tests/managed/api.zig#L2904).
