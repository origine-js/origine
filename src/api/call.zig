//! Per-call context for native bindings. `binding.native` builds one for every
//! JS-to-Zig call and passes it to functions that declare a `*Call` parameter.
//!
//! A `Call` is only valid inside the V8 callback that made it: it borrows the
//! callback info, the entered context, the scope's errno cell and a per-call arena.
const std = @import("std");
const v8 = @import("@v8");
const eu = @import("@util");
const errno = @import("errno.zig");
const binding = @import("binding.zig");

/// The entered isolate and context that values are created in.
pub const Env = struct {
    isolate: v8.Isolate,
    ctx: v8.Context,
    /// Set while building natives for a startup snapshot: the module index their state is
    /// resolved by at call time (see `binding.Rebinder`). Natives then carry a static marker
    /// instead of a state pointer, so the heap holds no process addresses.
    rebind: ?usize = null,
};

/// Writes the `Errno` for `err` into `cell` (mapped as `Call.fail` documents). Borrows
/// `cell` for the call only; retains nothing.
pub fn record(cell: *u32, err: anytype) void {
    const code = if (comptime errno.isBinding(@TypeOf(err))) errno.of(err) else errno.ofFs(err);
    cell.* = @intFromEnum(code);
}

pub const Call = struct {
    info: v8.FunctionCallbackInfo,
    isolate: v8.Isolate,
    ctx: v8.Context,
    /// The scope's native errno cell (borrowed). Failures write it; it is cleared on entry.
    errno_cell: *u32,
    ret: v8.ReturnValue,
    /// Per-call arena: decoded strings live here and are freed when the call ends.
    /// Use `allocSlice` / `print`, which panic on out-of-memory instead of failing.
    arena: std.mem.Allocator,

    pub fn init(info: v8.FunctionCallbackInfo, errno_cell: *u32, alloc: std.mem.Allocator) Call {
        const isolate = info.isolate();
        errno_cell.* = 0;
        return .{ .info = info, .isolate = isolate, .ctx = isolate.getCurrentContext(), .errno_cell = errno_cell, .ret = info.retval(), .arena = alloc };
    }

    /// Allocates `len` items from the per-call arena. Out of memory panics.
    pub fn allocSlice(self: *Call, comptime T: type, len: usize) []T {
        return self.arena.alloc(T, len) catch binding.oom();
    }

    /// Formats into the per-call arena. Out of memory panics.
    pub fn print(self: *Call, comptime fmt: []const u8, args: anytype) []u8 {
        return std.fmt.allocPrint(self.arena, fmt, args) catch binding.oom();
    }

    pub fn env(self: *const Call) Env {
        return .{ .isolate = self.isolate, .ctx = self.ctx };
    }

    /// Records `err` in the errno cell; the call then returns undefined. Errors from a
    /// closed binding set (`errno.Error`) map strictly (`errno.of`); anything else is
    /// an fs error, mapped by name (`errno.ofFs`).
    pub fn fail(self: *Call, err: anytype) void {
        record(self.errno_cell, err);
    }

    /// The raw JS argument at `index` (undefined when absent).
    pub fn arg(self: *const Call, index: usize) v8.Value {
        return self.info.get_arg(@intCast(index));
    }

    /// Encodes any supported Zig value (see `binding.encode`) as a JS value.
    pub fn value(self: *Call, x: anytype) !v8.Value {
        return binding.encode(self.env(), {}, x);
    }

    /// Builds a JS object from a comptime table of typed Zig functions (each becomes
    /// a native bound to `state`), nested tables and plain values. See `binding.object`.
    pub fn object(self: *Call, comptime State: type, state: *State, comptime table: anytype) !v8.Object {
        return binding.object(self.env(), State, state, table);
    }

    /// Sets an own data property on `target`.
    pub fn set(self: *Call, target: v8.Object, name: []const u8, x: anytype) !void {
        try binding.set(self.env(), target, name, x);
    }

    /// A new Uint8Array holding a copy of `data`.
    pub fn bytesValue(self: *Call, data: []const u8) !v8.Value {
        return binding.bytesValue(self.env(), data);
    }

    /// Starts a JS array that grows with `push`.
    pub fn array(self: *Call) ArrayBuilder {
        return .{ .env = self.env(), .array = eu.v.array(self.isolate, 0) };
    }
};

/// Appends encoded values to a JS array. `finish` yields the array value.
pub const ArrayBuilder = struct {
    env: Env,
    array: v8.Array,
    len: u32 = 0,

    pub fn push(self: *ArrayBuilder, x: anytype) !void {
        const encoded = try binding.encode(self.env, {}, x);
        if (!(self.array.object.setIndex(self.env.ctx, self.len, encoded) orelse return error.JavaScriptException)) return error.JavaScriptException;
        self.len += 1;
    }

    pub fn finish(self: ArrayBuilder) v8.Value {
        return self.array.object.value;
    }
};
