//! Typed JS-native bindings.
//!
//! Write a native as an ordinary Zig function; the binding layer does the V8 work:
//!
//! ```zig
//! fn openFile(g: *FsGrant, dir: DirRef, path: FilePath, bits: u32) !u32 { ... }
//! fn stat(g: *FsGrant, call: *Call, dir: DirRef, path: Path) !Stat { ... }
//!
//! const ops = try call.object(FsGrant, grant, .{
//!     .openFile = func(openFile, .{ .side_effect = .any }),
//!     .stat = func(stat, .{ .side_effect = .none }),
//!     .hot = func(hot, .{}).side_effect(.none).nofast(true), // builder style
//! });
//! ```
//!
//! - **Wrapping.** Every function in a table is wrapped in `func`, which states what V8
//!   cannot infer: `side_effect` (`.none`: reads nothing it could change, safe for
//!   throw-on-side-effect evaluation; `.receiver`: changes only its receiver; `.any`), is
//!   required and has no default, so each native is classified on purpose. `nofast`
//!   (default false) keeps a native off the fast API path even if its signature qualifies,
//!   and `constructor` (`.throw`, the default, or `.allow`) sets the constructor behavior;
//!   `.allow` implies no fast entry. A bare function in a table is a compile error.
//!
//! - **State.** The first parameter is the state pointer (`*State`) the function was
//!   bound to. `State` provides two methods: `errnoCell(self) *u32` (where failures are
//!   reported) and `allocator(self) std.mem.Allocator` (backing the per-call arena).
//! - **Arguments.** Every other parameter is decoded from the JS arguments in order
//!   (see `decode`): `u32`, `u64`, `f64`, `bool`, `[]const u8` (a string copied into the
//!   call arena), `[]u8` (the bytes of a typed array, aliased), `v8.Value`,
//!   `v8.Function`, `v8.Object`, `?T` (undefined or null gives null), or any type with
//!   `pub fn decode(call: *Call, index: usize) !T` and an optional `pub const arity`
//!   (how many JS arguments it consumes, default 1). A `*Call` parameter is injected
//!   and consumes no JS argument. A mistyped or missing argument fails with
//!   `error.InvalidArgument` before the function runs.
//! - **Results.** The return value (optionally an error union) is encoded (see
//!   `encode`): integers, floats, bools, strings, `?T`, slices and tuples (arrays),
//!   structs (objects), V8 handles, or any type with `pub fn encode(self, env) !v8.Value`.
//! - **Fast calls.** A native whose parameters are all `u32`, `f64` or `bool` (after
//!   the state) and whose result is void, bool, `u32`, `u64` or `f64` (or an
//!   error union of one) also gets a V8 fast API entry (`fast`), so optimized JS calls it
//!   without building a `FunctionCallbackInfo`. The slow callback stays as the fallback. On
//!   the fast path a failure still writes the errno cell but the result is zero rather than
//!   undefined; the guest reads the cell, so the difference is not observable there.
//! - **Errors.** A returned error is mapped to an `Errno` (errno.zig), written into the
//!   errno cell, and the call returns undefined. The guest reads the cell.
const std = @import("std");
const v8 = @import("@v8");
const call_mod = @import("call.zig");

pub const Call = call_mod.Call;
pub const Env = call_mod.Env;
pub const ArrayBuilder = call_mod.ArrayBuilder;

// ---- V8 helpers ------------------------------------------------------------

/// Allocation failure is not recoverable in a native: it panics rather than becoming
/// an error the guest could see.
pub fn oom() noreturn {
    @panic("OutOfMemory");
}

/// A JS string for UTF-8 `text`.
pub fn string(isolate: v8.Isolate, text: []const u8) v8.Value {
    return v8.String.initUtf8(isolate, text).name.primitive.value;
}

/// The bytes a typed array or DataView views, aliasing its backing store. Null for
/// anything else.
pub fn viewBytes(value: v8.Value) ?[]u8 {
    // from_opaque only wraps the handle; reading a non-view crashes, so check first.
    if (!value.isArrayBufferView()) return null;
    const view = v8.ArrayBufferView.from_opaque(value.data.handle) orelse return null;
    const length = view.byteLength();
    if (length == 0) return &.{};
    const buffer = view.buffer() orelse return null;
    const base: [*]u8 = @ptrCast(buffer.data() orelse return null);
    return base[view.byteOffset()..][0..length];
}

/// The state pointer a native was bound to: the function's data, either an External or (for
/// fast-call functions, whose data V8 will not pass to optimized code as an External) a
/// Number holding the address. Borrows the handle; valid while the state lives.
pub fn statePointer(comptime T: type, data: v8.Value) *T {
    if (data.isNumber()) {
        const number = v8.Number.from_opaque(data.data.handle).?;
        return @ptrFromInt(@as(usize, @intFromFloat(number.Value())));
    }
    return @ptrCast(@alignCast(v8.External.from_opaque(data.data.handle).?.pointer().?));
}

/// The state pointer a native was bound to (stored as the function's data).
pub fn externalPointer(comptime T: type, info: v8.FunctionCallbackInfo) *T {
    return statePointer(T, v8.Value.from_opaque(info.data().?.handle).?);
}

/// A new Uint8Array holding a copy of `data`.
pub fn bytesValue(env: Env, data: []const u8) !v8.Value {
    const store = v8.ArrayBuffer.newWithByteLength(env.isolate, data.len) orelse oom();
    if (data.len != 0) @memcpy(@as([*]u8, @ptrCast(store.data().?))[0..data.len], data);
    const array = v8.Uint8Array.init(store, 0, data.len) orelse oom();
    return array.typedArray.arrayBufferView.object.value;
}

// ---- natives ---------------------------------------------------------------

/// Wraps the typed function `callee` as a V8 callback. `callee` must take `*State` first;
/// see the file comment for argument, result and error handling.
pub fn native(comptime State: type, comptime callee: anytype) v8.FunctionCallback {
    return struct {
        fn callback(info: v8.FunctionCallbackInfo) callconv(.c) void {
            const state = externalPointer(State, info);
            var arena = std.heap.ArenaAllocator.init(state.allocator());
            defer arena.deinit();
            var call = Call.init(info, state.errnoCell(), arena.allocator());
            invoke(State, callee, state, &call) catch |err| call.fail(err);
        }
    }.callback;
}

fn invoke(comptime State: type, comptime callee: anytype, state: *State, call: *Call) !void {
    const Fn = @typeInfo(@TypeOf(callee)).@"fn";
    var args: std.meta.ArgsTuple(@TypeOf(callee)) = undefined;
    inline for (Fn.param_types, 0..) |maybe_type, position| {
        const P = maybe_type.?;
        if (position == 0) {
            if (P != *State) @compileError("the first parameter of a native must be the state pointer *" ++ @typeName(State));
            args[0] = state;
        } else if (P == *Call) {
            args[position] = call;
        } else {
            args[position] = try decode(P, call, comptime jsIndex(Fn.param_types, position));
        }
    }
    const Result = Fn.return_type.?;
    switch (@typeInfo(Result)) {
        .error_union => setReturn(call, try @call(.auto, callee, args)),
        else => setReturn(call, @call(.auto, callee, args)),
    }
}

/// The JS argument index of parameter `position`: the summed arity of the decoded
/// parameters before it (the state and `*Call` parameters take no JS argument).
fn jsIndex(comptime param_types: []const ?type, comptime position: usize) usize {
    var index: usize = 0;
    for (param_types[1..position]) |maybe_type| {
        if (maybe_type.? != *Call) index += arityOf(maybe_type.?);
    }
    return index;
}

/// Sets the JS return value. Integers, floats and bools take V8's direct paths.
fn setReturn(call: *Call, result: anytype) void {
    const T = @TypeOf(result);
    switch (@typeInfo(T)) {
        .void => {},
        .bool => call.ret.setBool(result),
        .int => if (result >= 0 and result <= std.math.maxInt(i32)) call.ret.setInt32(@intCast(result)) else call.ret.setDouble(@floatFromInt(result)),
        .float => call.ret.setDouble(result),
        else => call.ret.set(encode(call.env(), {}, result) catch |err| return call.fail(err)),
    }
}

// ---- fast calls ------------------------------------------------------------

const FastType = @FieldType(v8.CTypeInfo, "type");

/// The fast API type for a Zig parameter type, or null when only the slow path can
/// decode it.
fn fastParam(comptime T: type) ?FastType {
    return switch (T) {
        u32 => .Uint32,
        f64 => .Float64,
        bool => .Bool,
        else => null,
    };
}

/// The fast API type for a Zig result type, or null when only the slow path can encode it.
fn fastResult(comptime T: type) ?FastType {
    return switch (T) {
        void => .Void,
        u64 => .Uint64,
        else => fastParam(T),
    };
}

/// The payload of `T`, looking through an error union.
fn Payload(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .error_union => |union_info| union_info.payload,
        else => T,
    };
}

/// True when `callee` can be exposed through V8's fast API (see the file comment).
fn isFast(comptime State: type, comptime callee: anytype) bool {
    const Fn = @typeInfo(@TypeOf(callee)).@"fn";
    if (Fn.param_types.len == 0 or Fn.param_types.len > max_fast_args + 1 or Fn.param_types[0].? != *State) return false;
    inline for (Fn.param_types[1..]) |param| {
        if (fastParam(param.?) == null) return false;
    }
    return fastResult(Payload(Fn.return_type.?)) != null;
}

const max_fast_args = 6;

/// The fast API entry for `callee`: the C callback plus the static type description V8
/// and the overload list keep for as long as the function template lives (V8 retains
/// pointers into them rather than copying).
fn Fast(comptime State: type, comptime callee: anytype) type {
    return struct {
        const Fn = @typeInfo(@TypeOf(callee)).@"fn";
        const arity = Fn.param_types.len - 1;
        const Result = Payload(Fn.return_type.?);

        const types = blk: {
            // receiver, JS arguments, trailing callback options
            var out: [arity + 2]v8.CTypeInfo = undefined;
            out[0] = .{ .type = .V8Value, .flags = .{ .AllowSharedBit = false, .EnforceRangeBit = false, .ClampBit = false, .IsRestrictedBit = false } };
            for (Fn.param_types[1..], 1..) |param, slot| out[slot] = .{ .type = fastParam(param.?).?, .flags = out[0].flags };
            out[arity + 1] = .{ .type = .CallbackOptions, .flags = out[0].flags };
            break :blk out;
        };
        const info: v8.CFunctionInfo = .{
            .return_info_ = .{ .type = fastResult(Result).?, .flags = types[0].flags },
            .repr_ = .Number,
            .arg_count_ = arity + 2,
            .arg_info_ = &types[0],
        };

        pub const c_function: v8.CFunction = .{ .address_ = @constCast(entry()), .type_info_ = &info };
        /// The overload list V8 keeps a pointer to for the template's lifetime: static storage.
        pub const overloads = [_]v8.CFunction{c_function};

        fn P(comptime index: usize) type {
            return Fn.param_types[index + 1].?;
        }

        /// Runs `callee` with the state recovered from `options.data`. Borrows `options` for
        /// the call; a failure is recorded in the errno cell and yields a zero result.
        inline fn run(options: *const v8.FastApiCallbackOptions, js_args: anytype) Result {
            const state = statePointer(State, v8.Value.from_opaque(v8.fromRawLocal(options.data)).?);
            const cell = state.errnoCell();
            cell.* = 0;
            var args: std.meta.ArgsTuple(@TypeOf(callee)) = undefined;
            args[0] = state;
            inline for (0..arity) |index| args[index + 1] = js_args[index];
            if (@typeInfo(Fn.return_type.?) == .error_union) {
                return @call(.always_inline, callee, args) catch |err| {
                    call_mod.record(cell, err);
                    return std.mem.zeroes(Result);
                };
            }
            return @call(.always_inline, callee, args);
        }

        /// One C-ABI callback per arity; V8 passes the receiver first and the options last.
        fn entry() *const anyopaque {
            const Receiver = ?*const anyopaque;
            const Options = *const v8.FastApiCallbackOptions;
            return switch (arity) {
                0 => &struct {
                    fn f(_: Receiver, o: Options) callconv(.c) Result {
                        return run(o, .{});
                    }
                }.f,
                1 => &struct {
                    fn f(_: Receiver, a: P(0), o: Options) callconv(.c) Result {
                        return run(o, .{a});
                    }
                }.f,
                2 => &struct {
                    fn f(_: Receiver, a: P(0), b: P(1), o: Options) callconv(.c) Result {
                        return run(o, .{ a, b });
                    }
                }.f,
                3 => &struct {
                    fn f(_: Receiver, a: P(0), b: P(1), c: P(2), o: Options) callconv(.c) Result {
                        return run(o, .{ a, b, c });
                    }
                }.f,
                4 => &struct {
                    fn f(_: Receiver, a: P(0), b: P(1), c: P(2), d: P(3), o: Options) callconv(.c) Result {
                        return run(o, .{ a, b, c, d });
                    }
                }.f,
                5 => &struct {
                    fn f(_: Receiver, a: P(0), b: P(1), c: P(2), d: P(3), x: P(4), o: Options) callconv(.c) Result {
                        return run(o, .{ a, b, c, d, x });
                    }
                }.f,
                6 => &struct {
                    fn f(_: Receiver, a: P(0), b: P(1), c: P(2), d: P(3), x: P(4), y: P(5), o: Options) callconv(.c) Result {
                        return run(o, .{ a, b, c, d, x, y });
                    }
                }.f,
                else => unreachable,
            };
        }
    };
}

/// What a native may change, as V8's throw-on-side-effect evaluation sees it.
pub const SideEffect = enum {
    /// Observable state is never changed.
    none,
    /// Only the receiver may change.
    receiver,
    /// Anything may change.
    any,

    fn toV8(self: SideEffect) v8.SideEffectType {
        return switch (self) {
            .none => .HasNoSideEffect,
            .receiver => .HasSideEffectToReceiver,
            .any => .HasSideEffect,
        };
    }
};

/// Whether `new` on the native is allowed.
pub const Constructor = enum {
    throw,
    allow,

    fn toV8(self: Constructor) v8.ConstructorBehavior {
        return switch (self) {
            .throw => .Throw,
            .allow => .Allow,
        };
    }
};

/// Per-native settings for `func`.
pub const FuncOptions = struct {
    /// Required: the table cannot be built while this is unset.
    side_effect: ?SideEffect = null,
    /// Keep the native on the slow callback even if it could take the fast API path.
    nofast: bool = false,
    constructor: Constructor = .throw,
};

/// A native function plus its `Options`; build one with `func`. Immutable: each builder
/// method returns an updated copy. Comptime-only (it holds the function by pointer).
pub fn Wrapped(comptime F: type) type {
    return struct {
        callee: *const F,
        options: FuncOptions,

        pub const is_wrapped_native = true;
        const Self = @This();

        pub fn side_effect(self: Self, value: SideEffect) Self {
            var next = self;
            next.options.side_effect = value;
            return next;
        }

        pub fn nofast(self: Self, value: bool) Self {
            var next = self;
            next.options.nofast = value;
            return next;
        }

        pub fn constructor(self: Self, value: Constructor) Self {
            var next = self;
            next.options.constructor = value;
            return next;
        }
    };
}

/// Marks the typed Zig function `callee` as a native with `options` (see the file
/// comment); start a builder chain with `func(f, .{})`. Comptime only; retains nothing.
pub fn func(comptime callee: anytype, comptime options: FuncOptions) Wrapped(@TypeOf(callee)) {
    return .{ .callee = &callee, .options = options };
}

/// A JS function for `callee` bound to `state`. Uses a function template with a fast API
/// entry when `isFast` allows it (and `options` do not forbid it), else a plain function.
/// The returned handle is local to the current handle scope; `state` must outlive the function.
fn function(env: Env, comptime State: type, state: *State, comptime callee: anytype, comptime options: FuncOptions) v8.Function {
    const side_effect = options.side_effect.?.toV8();
    if (comptime options.nofast or options.constructor == .allow or !isFast(State, callee)) {
        const data = v8.External.init(env.isolate, state).value.data;
        return v8.Function.init(env.ctx, native(State, callee), data, 0, options.constructor.toV8(), side_effect);
    }
    const data = v8.Number.init(env.isolate, @floatFromInt(@intFromPtr(state))).numeric.primitive.value.data;
    var builder: v8.FunctionTemplate.Builder = .{};
    const template = builder.data(data).constructor_behavior(.Throw).side_effect_type(side_effect).build(env.isolate, native(State, callee), @constCast(&Fast(State, callee).overloads));
    return template.getFunction(env.ctx).?;
}

// ---- decoding --------------------------------------------------------------

/// How many JS arguments `T` consumes.
pub fn arityOf(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union" => if (@hasDecl(T, "arity")) T.arity else 1,
        else => 1,
    };
}

/// Decodes the JS argument at `index` as `T` (see the file comment for the supported
/// types). Fails with `error.InvalidArgument` on a type mismatch.
pub fn decode(comptime T: type, call: *Call, index: usize) !T {
    const arg = call.arg(index);
    if (T == u32) {
        if (!arg.isNumber()) return error.InvalidArgument;
        return arg.u32Value(call.ctx) orelse error.InvalidArgument;
    }
    if (T == u64) {
        if (!arg.isNumber()) return error.InvalidArgument;
        const number = arg.numberValue(call.ctx) orelse return error.InvalidArgument;
        if (!(number >= 0) or number > 9007199254740991.0) return error.InvalidArgument;
        return @intFromFloat(number);
    }
    if (T == f64) {
        if (!arg.isNumber()) return error.InvalidArgument;
        return arg.numberValue(call.ctx) orelse error.InvalidArgument;
    }
    if (T == bool) {
        if (!arg.isBoolean()) return error.InvalidArgument;
        return arg.booleanValue(call.isolate);
    }
    if (T == []const u8) {
        if (!arg.isString()) return error.InvalidArgument;
        const text = arg.toString(call.ctx) orelse return error.InvalidArgument;
        const buffer = call.allocSlice(u8, text.lenUtf8(call.isolate));
        return buffer[0..text.writeUtf8(call.isolate, buffer)];
    }
    if (T == []u8) return viewBytes(arg) orelse error.InvalidArgument;
    if (T == v8.Value) return arg;
    if (T == v8.Function) {
        if (!arg.isFunction()) return error.InvalidArgument;
        return v8.Function.from_opaque(arg.data.handle) orelse error.InvalidArgument;
    }
    if (T == v8.Object) {
        if (!arg.isObject()) return error.InvalidArgument;
        return arg.toObject(call.ctx) orelse error.InvalidArgument;
    }
    switch (@typeInfo(T)) {
        .optional => |optional| {
            if (arg.isUndefined() or arg.isNull()) return null;
            return try decode(optional.child, call, index);
        },
        .@"struct", .@"enum", .@"union" => if (@hasDecl(T, "decode")) return T.decode(call, index),
        else => {},
    }
    @compileError("no JS decoder for " ++ @typeName(T));
}

// ---- encoding --------------------------------------------------------------

/// Encodes a Zig value as a JS value. `state` is `{}` unless the value contains
/// functions, which only `object` supports (it knows the state type).
///
/// bool, integers, floats, `[]const u8` and string literals (strings), `?T` (undefined
/// for null), slices/arrays/tuples (arrays), named structs (objects), `v8.Value`, V8
/// handles with an `object` field, and types with `encode(self, env) !v8.Value`.
pub fn encode(env: Env, state: anytype, x: anytype) !v8.Value {
    _ = state;
    const T = @TypeOf(x);
    if (T == v8.Value) return x;
    switch (@typeInfo(T)) {
        .void => return v8.Primitive.initUndefined(env.isolate).value,
        .null => return v8.Primitive.initNull(env.isolate).value,
        .bool => return v8.Boolean.init(env.isolate, x).primitive.value,
        .comptime_int, .int => {
            if (x >= 0 and x <= std.math.maxInt(i32)) return v8.Number.initInt(env.isolate, @intCast(x)).numeric.primitive.value;
            return v8.Number.init(env.isolate, @floatFromInt(x)).numeric.primitive.value;
        },
        .comptime_float, .float => return v8.Number.init(env.isolate, x).numeric.primitive.value,
        .optional => return if (x) |inner| encode(env, {}, inner) else v8.Primitive.initUndefined(env.isolate).value,
        .pointer => |pointer| {
            if (pointer.size == .slice) {
                if (pointer.child == u8) return string(env.isolate, x);
                return encodeList(env, x);
            }
            if (pointer.size == .one) switch (@typeInfo(pointer.child)) {
                .array => |array| {
                    if (array.child == u8) return string(env.isolate, x);
                    return encodeList(env, x);
                },
                else => {},
            };
        },
        .array => return encodeList(env, &x),
        .@"struct" => |info| {
            if (@hasDecl(T, "encode")) return x.encode(env);
            if (@hasField(T, "object")) return x.object.value;
            if (T == v8.Object) return x.value;
            if (info.is_tuple) return encodeList(env, x);
            const target = v8.Object.init(env.isolate);
            inline for (info.field_names) |name| try set(env, target, name, @field(x, name));
            return target.value;
        },
        else => {},
    }
    @compileError("no JS encoder for " ++ @typeName(T));
}

fn encodeList(env: Env, items: anytype) !v8.Value {
    const array = v8.Array.init(env.isolate, 0);
    var index: u32 = 0;
    switch (@typeInfo(@TypeOf(items))) {
        .@"struct" => inline for (items) |item| {
            _ = array.object.setIndex(env.ctx, index, try encode(env, {}, item)) orelse return error.JavaScriptException;
            index += 1;
        },
        else => for (items) |item| {
            _ = array.object.setIndex(env.ctx, index, try encode(env, {}, item)) orelse return error.JavaScriptException;
            index += 1;
        },
    }
    return array.object.value;
}

/// True for named structs that `object` builds recursively (not tuples, handles or
/// types with their own `encode`).
fn isTable(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| !info.is_tuple and !@hasDecl(T, "encode") and !isHandle(T) and !isWrapped(T),
        else => false,
    };
}

/// True for the result of `func`.
fn isWrapped(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "is_wrapped_native");
}

/// V8 handle types encode to themselves rather than as tables or plain structs.
fn isHandle(comptime T: type) bool {
    return T == v8.Value or T == v8.Object or @hasField(T, "object");
}

/// Sets an own data property `name` on `target` to the encoded `x`.
pub fn set(env: Env, target: v8.Object, name: []const u8, x: anytype) !void {
    const ok = target.createDataProperty(env.ctx, v8.String.initUtf8(env.isolate, name).name, try encode(env, {}, x)) orelse return error.JavaScriptException;
    if (!ok) return error.JavaScriptException;
}

/// Builds an object from a comptime table. `func(...)` fields become natives bound to
/// `state` (see `native`; bare functions are rejected); named-struct fields become nested objects; everything else
/// is encoded as a plain value.
///
/// ```zig
/// const target = try binding.object(env, Scope, state, .{
///     .env = .{ .args = func(args, .{ .side_effect = .none }) },   // nested object of natives
///     .version = "1.0",                       // plain value
///     .open = func(open, .{ .side_effect = .any }),  // native
/// });
/// ```
pub fn object(env: Env, comptime State: type, state: *State, comptime table: anytype) !v8.Object {
    const target = v8.Object.init(env.isolate);
    inline for (@typeInfo(@TypeOf(table)).@"struct".field_names) |name| {
        const field = @field(table, name);
        const F = @TypeOf(field);
        if (comptime isWrapped(F)) {
            if (comptime field.options.side_effect == null) @compileError("native `" ++ name ++ "` needs an explicit side_effect: func(f, .{ .side_effect = .none })");
            try set(env, target, name, function(env, State, state, field.callee.*, field.options).object.value);
            continue;
        }
        switch (@typeInfo(F)) {
            .@"fn" => @compileError("native `" ++ name ++ "` must be wrapped: func(f, .{ .side_effect = .none | .receiver | .any })"),
            else => if (comptime isTable(F)) {
                try set(env, target, name, (try object(env, State, state, field)).value);
            } else {
                try set(env, target, name, field);
            },
        }
    }
    return target;
}
