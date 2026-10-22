//! `origine:@std/text`: UTF-8 encode and strict decode. The natives hold no authority;
//! they reach this module alone, as `import.meta.native`, which it captures and deletes.
const std = @import("std");
const v8 = @import("@v8");
const eu = @import("@util");
const binding = @import("../binding.zig");
const Call = binding.Call;
const module = @import("../module.zig");
const ScopeState = @import("../host.zig").ScopeState;
const simdutf = v8.simdutf;

pub fn modules() [1]module.Module {
    const natives = struct {
        /// The UTF-8 bytes of the string `value` as a new Uint8Array; lone surrogates become
        /// U+FFFD. The JS wrapper guarantees a string; anything else is an InvalidArgument.
        pub fn encode(state: *ScopeState, call: *Call, value: v8.Value) !v8.Value {
            _ = state;
            if (!value.isString()) return error.InvalidArgument;
            const text = v8.String.from_opaque(value.data.handle) orelse return error.InvalidArgument;
            const length = text.lenUtf8(call.isolate);
            const store = eu.v.array_buffer(call.isolate, length) orelse binding.oom();
            if (length != 0) _ = text.writeUtf8(call.isolate, @as([*]u8, @ptrCast(store.data().?))[0..length]);
            const array = v8.Uint8Array.init(store, 0, length) orelse binding.oom();
            return array.typedArray.arrayBufferView.object.value;
        }

        /// Borrows a view local for this call and returns a string local in its handle
        /// scope, or undefined for invalid UTF-8. Unshared bytes are borrowed; shared
        /// bytes are copied atomically into the call arena before validation, so no
        /// shared mutable slice escapes. Invalid arguments retain no resources.
        pub fn decode(state: *ScopeState, call: *Call, value: v8.Value) !?v8.Value {
            _ = state;
            const bytes = binding.viewBytes(value) orelse shared: {
                if (!value.isArrayBufferView()) return error.InvalidArgument;
                const view = v8.ArrayBufferView.from_opaque(value.data.handle).?;
                const buffer = view.buffer() orelse return error.InvalidArgument;
                if (!buffer.object.value.isSharedArrayBuffer()) return error.InvalidArgument;
                const copied = call.allocSlice(u8, view.byteLength());
                if (copied.len == 0) break :shared copied;
                const base: [*]const u8 = @ptrCast(buffer.data() orelse return error.InvalidArgument);
                for (copied, 0..) |*byte, index| byte.* = @atomicLoad(u8, &base[view.byteOffset() + index], .monotonic);
                break :shared copied;
            };
            if (simdutf.validateAscii(bytes)) return eu.v.str_one_byte(call.isolate, bytes).name.primitive.value;
            const units = call.allocSlice(u16, bytes.len);
            const written = simdutf.convertUtf8ToUtf16(bytes, units);
            if (written == 0) return null;
            return eu.v.str_two_byte(call.isolate, units[0..written]).name.primitive.value;
        }
    };
    return .{.{
        .id = "origine:@std/text",
        .source = @embedFile("../../js/std/text.js"),
        .bindings = module.stateless(.{
            .encode = binding.func(natives.encode, .{ .side_effect = .none }),
            .decode = binding.func(natives.decode, .{ .side_effect = .none }),
        }),
    }};
}
