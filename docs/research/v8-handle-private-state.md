# V8 fast calls and JS handle classes

Investigated 2026-10-29. This is research, not an implementation change or a benchmark.
The local V8 checkout is 15.8.30 at `a98309795399032afd2f191adaa94ed6e9918437`.

## Findings

1. **V8 Fast API accepts value/object arguments.** The pinned header maps
   `v8::Local<v8::Value>`, `v8::Local<v8::Object>`, and `v8::Local<v8::Array>` to
   `kV8Value`. These arguments do not prove a particular resource type; the callback
   or its trusted JS wrapper still validates them. The scalar-only limitation is
   in origine's `src/api/binding.zig`: `fastParam` accepts only `u32`, `f64`, and
   `bool`. Origine already describes the implicit receiver as `V8Value`, but its
   generated fast entries ignore that receiver. Extending argument support also
   requires converting the raw Local ABI representation; merely adding another
   enum case is insufficient. See the existing `v8.fromRawLocal` helper.
   [Pinned V8 type mapping](https://github.com/v8/v8/blob/a98309795399032afd2f191adaa94ed6e9918437/include/v8-fast-api-calls.h#L565-L569),
   [Node's Fast API argument validation guidance](https://github.com/nodejs/node/blob/main/doc/contributing/adding-v8-fast-api.md#type-checking).

2. **A JS class instance can carry `v8::Private` state.** `SetPrivate`, `GetPrivate`,
   and `HasPrivate` operate on `v8::Object`; an ObjectTemplate with internal fields
   is not required. Check a generic Value is an object before casting it. Stamp
   the object at construction, and read/validate the stamp inside the actual
   native operation. That removes the separate `nativeIs(handle)` boundary
   crossing. It does not eliminate the private-property lookup inside the call.
   Setting a private property may allocate: it is construction work, not a reason
   to restamp the object on each operation.
   [Pinned public API](https://github.com/v8/v8/blob/a98309795399032afd2f191adaa94ed6e9918437/include/v8-object.h#L449-L458),
   [SetPrivate implementation](https://github.com/v8/v8/blob/a98309795399032afd2f191adaa94ed6e9918437/src/api/api.cc#L4964-L4995).

3. **ES private fields and V8 API-private keys are different mechanisms.**
   `#id` is lexically scoped to its class. `Private::ForApi("id")` does not recover
   that field by spelling. V8 creates API private symbols through its API-private
   symbol table; ES private fields are created as private-name symbols. JS can
   unwrap `#id` and pass the value, or native code can read a separate API-private
   stamp attached at construction. The two can coexist on an ordinary JS object.
   `ForApi` uses a global isolate namespace and its symbols are not collected;
   use a fixed qualified key, not a fresh name per handle.
   [API-private symbol creation](https://github.com/v8/v8/blob/a98309795399032afd2f191adaa94ed6e9918437/src/api/api.cc#L9830-L9847),
   [ES private-name creation](https://github.com/v8/v8/blob/a98309795399032afd2f191adaa94ed6e9918437/src/runtime/runtime-symbol.cc#L23-L42),
   [Private API documentation](https://v8.github.io/api/head/classv8_1_1Private.html).

4. **`#field` access already brands the JS receiver.** A forged prototype does not
   create the private field. Accessing `this.#id` on a forged receiver throws in JS,
   before any native call. Native code still validates resource ownership, type,
   closed state, and IDs/generations. A private field alone does not prevent a
   public constructor from accepting an arbitrary ID: gate construction when the
   ID confers access. Do not rely on `instanceof` as the brand check.
   [V8 private brand checks](https://v8.dev/features/private-brand-checks),
   [V8 class-field implementation](https://v8.dev/blog/faster-class-features).

5. **The old header's fast-call restrictions are stale for this pinned engine.**
   Its introductory prose still describes no allocation/reentry and a fallback
   option; the actual `FastApiCallbackOptions` has isolate/data, without that
   fallback member. The same pinned checkout tests fast callbacks allocating,
   triggering GC in C++ and JS, and throwing through reentrant JS. Current Node
   guidance requires a HandleScope before operations creating Local handles.
   Consequently, blanket claims that GetPrivate/SetPrivate are forbidden because
   fast callbacks can never allocate are incorrect here. Rooting, raw buffer
   lifetimes, and callback ABI requirements still matter.
   [Pinned fast-call allocation/reentry tests](https://github.com/v8/v8/blob/a98309795399032afd2f191adaa94ed6e9918437/test/cctest/test-api.cc#L29515-L29592),
   [Pinned options layout](https://github.com/v8/v8/blob/a98309795399032afd2f191adaa94ed6e9918437/include/v8-fast-api-calls.h#L455-L480),
   [Node handle-scope guidance](https://github.com/nodejs/node/blob/main/doc/contributing/adding-v8-fast-api.md#stack-allocated-objects-and-garbage-collection).

## Two viable designs for origine

### JS class, private fields, scalar resource ID

Illustrative code, with existing errno/error handling omitted:

```js
const token = {};
class Handle {
  #id;
  constructor(key, id) {
    if (key !== token) throw new TypeError('Use the resource factory');
    this.#id = id;
  }
  close() {
    return native.close(this.#id);
  }
}
const wrap = id => new Handle(token, id);
```

`#id` access supplies JS receiver validation; `native.close` looks up and validates
that resource in the current owner/scope. One JS-to-native crossing. A scalar-only
operation like this fits the existing binding fast path. Operations passing a
buffer/string still need the corresponding binding support; changing the handle
representation alone does not make every filesystem operation fast.

For APIs shaped as `fs.read(handle, ...)`, the class can supply a closure-private
unwrap helper which accesses `handle.#id`; it need not expose a public ID accessor.
If IDs are reused, the resource table must account for stale references through
appropriate generations or another ownership/lifetime policy. Private fields do
not solve ID reuse.

### JS class, native-private stamp, value argument

Construct an ordinary JS Handle, stamp native-only metadata once with SetPrivate,
and pass the object to `native.read(handle, ...)`. A fast callback accepting
`Local<Value>` checks object/stamp/type and the resource's owner/liveness within
that operation. This keeps native-side identity without imposing native class
construction or an extra validator call. Extend and test origine's fast argument
ABI first; keep the slow callback equivalent.

## Recommendation and limits

For table-owned files/directories and I/O resources, start with JS classes and
`#field` resource IDs, following Deno's public file/network wrappers (see the
companion Deno note). Use a separate V8-private stamp only where the actual native
operation must consume an opaque JS object. Native class templates/internal fields
remain useful for directly wrapped native state, but are not required merely to
prevent forged JS records.

These are architecture conclusions from source inspection. No claim is made that
Private lookup, internal fields, WeakSet lookup, or #field unwrapping wins a timing
benchmark. A follow-up experiment should force optimized fast entry execution,
compare slow/fast results, test forged objects/proxies and borrowed methods, and
exercise close/reuse, cross-scope ownership, GC, and snapshot restoration. Do not
store process pointers as snapshot state.
