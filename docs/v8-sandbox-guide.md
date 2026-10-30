# V8 sandbox guide

origine enables the V8 sandbox by default. You will likely need it when sharing resources between native (Zig) code and JavaScript, so this page covers the pattern for each direction.

With the sandbox on, V8 only accepts ArrayBuffer backing stores that live inside the sandbox. A store outside it aborts the process. Check at runtime with `v8.V8.isSandboxEnabled()`.

## Native → JS

### Strings

Prefer external strings. Create them with `v8::String::NewExternalOneByte` or `v8::String::NewExternalTwoByte` so V8 reads the bytes in place instead of copying them. The resource must stay alive for as long as the string can be reached from JS.

### ArrayBuffer

If native code allocates the backing store, allocate it from the sandbox with `v8.ArrayBuffer.Allocator.fromSandbox()`. It is backed by a mimalloc heap over an arena inside the sandbox, and stores are zeroed on request and reused.

Create one allocator per process and share it. Every isolate that makes ArrayBuffers takes the same one, as `.array_buffer_allocator = .{ .borrowed = aba }` on `Runtime.create` (see [src/managed/runtime.zig](../src/managed/runtime.zig)) and as `array_buffer_allocator` on `init_snapshot.create`. Each `fromSandbox()` call makes its own heap and arena, so a new one per isolate would multiply them. [src/main.zig](../src/main.zig) shows the pattern. Deinit the allocator after all isolates and backing stores are released, and before `V8.dispose`.

Memory from a Zig allocator (`fromZig`) cannot live inside the sandbox, so it only works when the sandbox is disabled.

**TODO:** `SandboxState`, the allocator's internal state, is not yet exposed outside `lib/v8_zig/src/v8/ArrayBuffer.zig`, so `src/` cannot inspect the arena.

## JS → native

### Strings

V8 provides `v8::String::ValueView`, which gives direct access to the flat one-byte or two-byte contents without copying through `String::Write`.

- Keep the view short-lived. Do not run JS or allocate on the V8 heap while holding it, because a GC can move the string.
- Not used in origine yet. Confirm the API against the V8 version we build with before relying on it.
