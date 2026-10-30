# JS handles and API construction

Graph descriptors, filesystem references and grants, runtime handles, ports, timers,
and result records are ordinary JS class instances. Factories hold a closure-private
construction token. Retrieving `handle.constructor` does not reveal that token;
`new handle.constructor(otherId)` and forged prototypes cannot create valid handles.

Glue imports the registry from its private `records.js` ES module. Embedded std
wrappers use normal named imports from `origine:@internal/records`, which exposes
that same realm's registry through the module loader. Glue hands std a value it owns
with `publish(name, value)` (first publication wins), and std reads it with
`internal(name)`; the cache operations of `origine:@std/graph/cache` travel this way. Guest imports are denied,
and the registry is never placed in `import.meta.native`. Evaluated private exports
and their class identities survive init snapshots.

Instances use JS `#fields` for their type and prepared state. Private brand checks
and unwrapping run in JavaScript, without calling a native validator. File and
directory operations unwrap private reference state and cross into their grant-bound
native operation once with scalar IDs. Native code still validates the grant owner,
resource type, access, liveness, and arguments. A resource reference alone confers no
authority; the grant supplies it.

Factories allocate an immutable instance and retain their prepared field state.
JS validation copies mutable caller option dictionaries and arrays before construction.
Raw native grants retain their V8-private authority stamp and are hidden in the JS
grant wrapper's private state. Neither public fields nor getters can substitute for
private state. There are no public static unwrap helpers on the instance's constructor.

Filesystem tables issue fresh IDs rather than reusing closed IDs. Old aliases stay
invalid when another file or directory opens. Tables retain issued-slot metadata until
the grant/runtime is destroyed; resource IDs are scoped to that table. Close and
release still free the underlying resource according to the existing lifecycle.

Existing API namespaces, option dictionaries, arrays, and network classes remain JS.
The generic native-record constructors, native identity callbacks, and their snapshot
external references have been removed. V8 value/object fast arguments are supported
where an operation needs them, with native object validation inside that operation.
See [fast calls](../src/api/docs/fast-calls.md) for ABI and handle-scope requirements.
No timing speedup is claimed; tests force optimization to verify the fast entry.

## Errors

`origine:@std/errors` exports `OrigineError extends Error`, and its subclasses
`IoError`, `HostError`, and `ImportError`. The same constructors are re-exported from
`origine:@std/io` and `origine:@std/graph/import` and used by glue and Rust promise
rejections. Construct with `(errno, message = '')`; construction allocates an Error
and captures its stack. Instances expose `errno`, `name`, `message`, and `stack`.
Existing code constants, `name(code)`, `is(value, code)`, `of(code, message)`,
`IoError.check`, and `ImportError.other` remain available. `nameOf(code)` is inherited
from the base class. The shared synchronous errno cell still must be read/cleared
by the operation's existing protocol.

## Private ES module glue

The host compiles and evaluates the embedded glue module graph, reads its namespace's
named `create` export, calls `create(native)`, and supplies the resulting API to
`main(api, data)`. Glue parts use static relative ES imports. They are not entries in
the guest's module resolver and cannot be imported by guest code.

All JS factories are available after evaluation. Capability getters bind permitted
native callbacks through `native.bind`; this binds authority only and never loads
or evaluates JavaScript. Optional I/O backends still initialize on first use.
Code caches are stored per ES module under `origine:glue.esm.*`; former script cache
identities are not reused.

Snapshots preserve the module's `create` function, API objects, JS constructors,
private construction tokens, and `#field` state. No host pointer is stored in JS
private state during snapshot preparation. Resource authority is bound per restored
scope. Closed or released resources do not regain authority after restoration.

## API guideline checklist

1. Factory and operation names retain their existing results and behavior; errors
   now have standard Error behavior. `create(native)` returns the API.
2. Record factories allocate and retain their prepared fields; JS copies input
   dictionaries/arrays as described above. Error construction captures a stack.
   Resources retain their existing explicit open, close, and buffer-transfer costs.
3. Literal-shaped handles are no longer an alternate representation. Existing
   factories remain the one construction path; no public construction-token or private-state accessor is exposed.
4. Existing short public names are retained. The shared base is `OrigineError`;
   domain names remain `IoError`, `HostError`, and `ImportError`.
5. Invalid input remains `InvalidInput`, forged receivers fail identity validation,
   and ownership, stale-resource, permission, missing-file, and unsupported-operation
   errors retain their existing errno meanings.

## Narrowing API cleanup

`api.host.env` exposes only `args`, `get`, and `list`; the filtered-view `narrow`
method and `EnvNarrow` type have been removed. Reads retain their existing return
values. `args` and `list` allocate frozen arrays; `get` returns a value or undefined.
No replacement alias is provided. `api.io.narrow` remains because its backend
restrictions and shared live-runtime quotas have concrete effects. Invalid I/O
narrowing options still throw TypeError, and a disallowed backend or exhausted
quota still raises Unsupported. Internal Zig `errno.narrow` remains the error-set
conversion boundary and is unrelated to capability narrowing.
