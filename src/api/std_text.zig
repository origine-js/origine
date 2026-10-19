//! `origine:@std/text`: UTF-8 encode and strict decode. The natives hold no authority;
//! they reach this module alone, as `import.meta.native`, which it captures and deletes.
const std = @import("std");
const v8 = @import("@v8");
const binding = @import("binding.zig");
const Call = binding.Call;
const module = @import("module.zig");
const ScopeState = @import("host.zig").ScopeState;
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
            const store = v8.ArrayBuffer.newWithByteLength(call.isolate, length) orelse binding.oom();
            if (length != 0) _ = text.writeUtf8(call.isolate, @as([*]u8, @ptrCast(store.data().?))[0..length]);
            const array = v8.Uint8Array.init(store, 0, length) orelse binding.oom();
            return array.typedArray.arrayBufferView.object.value;
        }

        /// The string for strictly valid UTF-8 `bytes` (a typed array's bytes, aliased for the
        /// call), or undefined when they are not. ASCII becomes a one-byte string; anything
        /// else is validated and transcoded by simdutf in one pass, using up to
        /// `2 * bytes.len` bytes of the call arena.
        pub fn decode(state: *ScopeState, call: *Call, bytes: []u8) ?v8.Value {
            _ = state;
            if (simdutf.validateAscii(bytes)) return v8.String.initOneByte(call.isolate, bytes).name.primitive.value;
            const units = call.allocSlice(u16, bytes.len);
            const written = simdutf.convertUtf8ToUtf16(bytes, units);
            if (written == 0) return null;
            return v8.String.initTwoByte(call.isolate, units[0..written]).name.primitive.value;
        }
    };
    return .{.{
        .id = "origine:@std/text",
        .source = @embedFile("../js/std_text.js"),
        .bindings = module.stateless(.{
            .encode = binding.func(natives.encode, .{ .side_effect = .none }),
            .decode = binding.func(natives.decode, .{ .side_effect = .none }),
        }),
    }};
}
