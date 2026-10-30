//! Value/object argument ABI and receiver validation on optimized V8 fast calls.
const std = @import("std");
const t = std.testing;
const v8 = @import("@v8");
const m = @import("@managed");
const binding = m.Api.binding;
const ensureV8 = @import("../support.zig").ensureV8;
const check = @import("support.zig").check;

const State = struct {
    cell: u32 = 0,
    detached: bool = false,
    calls: u32 = 0,
    pub fn errnoCell(self: *@This()) *u32 {
        return &self.cell;
    }
    pub fn allocator(_: *@This()) std.mem.Allocator {
        return t.allocator;
    }
    pub fn isDetached(self: *@This()) bool {
        return self.detached;
    }
};

fn classify(state: *State, value: v8.Value, fail: bool) !u32 {
    state.calls += 1;
    if (fail) return error.Unsupported;
    if (value.isUndefined()) return 1;
    if (value.isNull()) return 2;
    if (value.isObject()) return 3;
    if (value.isNumber()) return 4;
    if (value.isBoolean()) return 5;
    return 6;
}

fn stampKey(isolate: v8.Isolate) v8.Private {
    return v8.Private.forApi(isolate, v8.String.initUtf8(isolate, "origine:test/fast-value"));
}

fn readStamp(state: *State, object: v8.Object, fail: bool) !u32 {
    state.calls += 1;
    if (fail) return error.Unsupported;
    const isolate = v8.Isolate.getCurrent();
    const context = isolate.getCurrentContext();
    const stamp = object.getPrivate(context, stampKey(isolate)) orelse return error.JavaScriptException;
    if (!stamp.isNumber()) return error.InvalidInput;
    return stamp.u32Value(context) orelse error.InvalidInput;
}

// A handle argument must not accidentally make handle-valued returns fast eligible.
fn returnValue(_: *State, value: v8.Value, fail: bool) !v8.Value {
    if (fail) return error.Unsupported;
    return value;
}

fn install(scope: *m.Scope, state: *State) !void {
    var session: m.Scope.Session = undefined;
    session.init(scope);
    defer session.deinit();
    const env: binding.Env = .{ .isolate = session.isolate(), .ctx = session.ctx };
    const object = try binding.object(env, State, state, .{
        .value = binding.func(classify, .{ .side_effect = .any }),
        .object = binding.func(readStamp, .{ .side_effect = .any }),
        .returned = binding.func(returnValue, .{ .side_effect = .none }),
    });
    const stamped = v8.ObjectTemplate.initDefault(env.isolate).?.initInstance(env.ctx).?;
    const number = v8.Integer.init(env.isolate, 23);
    try t.expect(stamped.setPrivate(env.ctx, stampKey(env.isolate), number.number.numeric.primitive.value) orelse false);
    try binding.set(env, env.ctx.getGlobal(), "native", object.value);
    try binding.set(env, env.ctx.getGlobal(), "stamped", stamped.value);
}

test "binding: fast value and object arguments preserve cold-path semantics" {
    ensureV8();
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const scope = try rt.createScope(.{});
    var state: State = .{};
    try install(scope, &state);
    try check(scope,
        \\native.value(undefined, false) === 1 && native.value(null, false) === 2 &&
        \\native.value({}, false) === 3 && native.value(0, false) === 4 &&
        \\native.value(false, false) === 5 && native.object(stamped, false) === 23 &&
        \\native.returned(stamped, false) === stamped && native.object(0, false) === undefined
    );
    try t.expectEqual(@backingInt(m.Api.errnoOf(error.InvalidArgument)), state.cell);
    // Deliberate failure yields 0 on optimized fast entries versus undefined cold.
    try check(scope,
        \\globalThis.valueFast = (x, fail) => native.value(x, fail);
        \\globalThis.objectFast = (x, fail) => native.object(x, fail);
        \\globalThis.returnedSlow = (x, fail) => native.returned(x, fail);
        \\%PrepareFunctionForOptimization(valueFast);
        \\%PrepareFunctionForOptimization(objectFast);
        \\%PrepareFunctionForOptimization(returnedSlow);
        \\valueFast(stamped, false); valueFast(stamped, false);
        \\objectFast(stamped, false); objectFast(stamped, false);
        \\returnedSlow(stamped, false); returnedSlow(stamped, false);
        \\%OptimizeFunctionOnNextCall(valueFast);
        \\%OptimizeFunctionOnNextCall(objectFast);
        \\%OptimizeFunctionOnNextCall(returnedSlow);
        \\valueFast(stamped, true) === 0 && objectFast(stamped, true) === 0 &&
        \\returnedSlow(stamped, true) === undefined && returnedSlow(stamped, false) === stamped
    );
    // Exercise direct-Local Smi zero, all primitives, proxies and forged prototypes.
    try check(scope,
        \\valueFast(0, false) === 4 && valueFast(undefined, false) === 1 &&
        \\valueFast(null, false) === 2 && valueFast(false, false) === 5 &&
        \\valueFast("text", false) === 6 && valueFast(Symbol(), false) === 6 && valueFast(1n, false) === 6 &&
        \\valueFast(new Proxy({}, {}), false) === 3 && objectFast(stamped, false) === 23
    );
    const calls = state.calls;
    try check(scope, "objectFast(0, false) === 0 && objectFast(null, false) === 0 && objectFast(undefined, false) === 0");
    try t.expectEqual(calls, state.calls);
    try t.expectEqual(@backingInt(m.Api.errnoOf(error.InvalidArgument)), state.cell);
    try check(scope, "objectFast(Object.create(stamped), false) === 0 && objectFast(new Proxy(stamped, {}), false) === 0");
    try t.expectEqual(@backingInt(m.Api.errnoOf(error.InvalidArgument)), state.cell);
    state.detached = true;
    const before_detached = state.calls;
    try check(scope, "valueFast(stamped, false) === 0 && objectFast(stamped, false) === 0");
    try t.expectEqual(before_detached, state.calls);
    try t.expectEqual(@backingInt(m.Api.errnoOf(error.StaleHandle)), state.cell);
}
