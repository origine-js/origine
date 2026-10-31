# JS handles and API construction

Init JS is trusted, so the handles the API hands it behave like integer file descriptors: ordinary
frozen class instances with public fields that init JS can read, rebuild and wrap as it likes. Authority
never sits in a handle. The natives validate the grant owner, the resource type, access, liveness and
every id; ids are issued fresh and never reused while their table lives, so a stale or rebuilt id names
nothing it should not. A resource reference alone confers no authority; the grant supplies it.

## Classes

`src/js/glue/handle.js` has the two bases:

- `Handle` is a native resource (`FileHandle`, `DirHandle`, `FsGrant`). It keeps the issuer it was made
  with in a private field, read with `issuerOf(value)`.
- `Data` is a frozen record of public fields (`Stat`, `DirEntry`, requests and results of the graph glue,
  the descriptors of `origine:@std/graph/*`). Checks are `instanceof`.

`FileHandle` and `DirHandle` carry `kind`, `fs` (the issuing grant's id) and `id`. `Dir.at(fs, id)` and
`File.at(fs, id)` of `origine:@std/io` rebuild one without an issuer. An `fs` grant is a `Handle` whose
issuer is the native grant behind it: `issuerOf` of the real object is the only way to that native, so a
copy, a proxy or an object inheriting from a grant is not a grant (`derive({ fs })` refuses it).

Classes that more than one module makes or checks are declared in `src/js/glue/handles.js`; one module's
own classes are declared in that module and extend `Handle` or `Data`. Embedded std modules import the same
file as `origine:@internal/handles` (`import * as h`): the module map adopts the evaluated `handles.js` of
the realm's glue (`ModuleMap.adopt`), so a table asked for that id links to the one instance instead of
calling the loader, and glue and std share the same classes. Only embedded `origine:` modules may import it
(`src/api/internal.zig`); guest imports are denied. A snapshot keeps the module as data of the context and a
restored scope adopts it again. Glue hands std a value it owns with `provide(name, value)` (first provision
wins) and std reads it with `provided(name)`; the cache operations of `origine:@std/graph/cache` travel this way.

## Hardened grants

`api.fs.requestSync` and `requestAsync` take a required option `handle: 'plain' | 'hardened'`. Every grant
mints an issuer for the file and directory handles it issues. A plain grant does not look at it. A hardened
grant compares the issuer of each handle argument before it calls a native and answers `InvalidInput` for a
handle it did not issue, a rebuilt one or a hand-made one; the `Dir.cwd()` sentinel (`fs` 0, `id` 0) names no
resource and is always accepted. The std methods rewrap a result of the grant and keep its issuer. The cost is
one comparison per handle argument; a plain grant pays nothing.

Instances are frozen and allocated by their class; a handle retains its prepared fields. Validation copies
mutable caller option dictionaries and arrays before construction. File and directory operations pass the
`fs` and `id` of a handle to their grant-bound native once.

Filesystem tables issue fresh IDs rather than reusing closed IDs. Old aliases stay invalid when another file
or directory opens. Tables retain issued-slot metadata until the grant/runtime is destroyed; resource IDs are
scoped to that table. Close and release still free the underlying resource according to the existing lifecycle.

Existing API namespaces, option dictionaries, arrays, and network classes remain JS. V8 value/object fast
arguments are supported where an operation needs them, with native object validation inside that operation.
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
