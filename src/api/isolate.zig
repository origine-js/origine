//! `api.isolate`: natives that start and watch isolates on other threads (`thread_isolate.zig`).
//! The channel ends that connect parent and child, and the child's `data`, are made by the glue
//! (`native.channel.*`); these natives only receive their handles.
const std = @import("std");
const errno = @import("errno.zig");
const env_api = @import("env.zig");
const host_api = @import("host.zig");
const ScopeState = host_api.ScopeState;
const ThreadIsolate = @import("thread_isolate.zig").ThreadIsolate;
const Call = @import("binding.zig").Call;

comptime {
    errno.requireBinding(spawn);
    errno.requireBinding(terminate);
    errno.requireBinding(outcome);
    errno.requireBinding(failure);
    errno.requireBinding(link);
}

/// `native.isolate.spawn(init, argsJson, envJson, rx, tx, done, data)`: starts an isolate running
/// `init` (a module specifier), with `args` (a JSON array of strings; the child sees the specifier
/// first, as the process entry point does) and `env` (a JSON array of alternating names and values).
/// `rx`/`tx` are the channel ends the child is given and `done` one that is closed when it ends;
/// all three are closed when the thread ends. `data` is a stash id (0: none). Returns the isolate id.
/// `PermissionDenied` when the embedder gave no `isolates`, `QuotaExceeded` past `max`,
/// `InvalidInput` for malformed JSON.
pub fn spawn(state: *ScopeState, init: []const u8, args_json: []const u8, env_json: []const u8, rx: u32, tx: u32, done: u32, data: f64) errno.Error!u32 {
    return spawnImpl(state, init, args_json, env_json, rx, tx, done, data) catch |err| return errno.narrow(err);
}

fn spawnImpl(state: *ScopeState, init: []const u8, args_json: []const u8, env_json: []const u8, rx: u32, tx: u32, done: u32, data: f64) !u32 {
    const host = state.host;
    const config = host.isolates orelse return error.PermissionDenied;
    if (host.children.items.len >= config.max) return error.QuotaExceeded;
    if (!(data >= 0) or data > 9007199254740991) return error.InvalidInput;
    const alloc = host.allocator;
    const args_parsed = std.json.parseFromSlice([]const []const u8, alloc, args_json, .{}) catch return error.InvalidInput;
    defer args_parsed.deinit();
    const env_parsed = std.json.parseFromSlice([]const []const u8, alloc, env_json, .{}) catch return error.InvalidInput;
    defer env_parsed.deinit();
    if (env_parsed.value.len % 2 != 0) return error.InvalidInput;
    const pairs = try alloc.alloc(env_api.Pair, env_parsed.value.len / 2);
    defer alloc.free(pairs);
    for (pairs, 0..) |*pair, index| pair.* = .{ .name = env_parsed.value[index * 2], .value = env_parsed.value[index * 2 + 1] };
    // The child sees the init specifier first, then the arguments.
    const argv = try alloc.alloc([]const u8, args_parsed.value.len + 1);
    defer alloc.free(argv);
    argv[0] = init;
    @memcpy(argv[1..], args_parsed.value);
    try host.children.ensureUnusedCapacity(alloc, 1);
    const child = try ThreadIsolate.spawn(alloc, .{
        .init = init,
        .args = argv,
        .env = pairs,
        .fs = host.fs,
        .runtime = host.runtime,
        .array_buffer_allocator = config.array_buffer_allocator,
        .platform = config.platform,
        .engine_snapshot = config.engine_snapshot,
        .isolates = config,
        .link = .{ .rx = rx, .tx = tx, .data = @intFromFloat(data) },
        .release = &.{ rx, tx, done },
    });
    host.children.appendAssumeCapacity(child);
    return @intCast(host.children.items.len);
}

fn childOf(state: *ScopeState, id: u32) !*ThreadIsolate {
    const items = state.host.children.items;
    if (id == 0 or id > items.len) return error.BadHandle;
    return items[id - 1];
}

/// `native.isolate.terminate(id)`: asks the isolate to stop; it ends at its next turn. Idempotent.
/// `BadHandle` for an unknown id.
pub fn terminate(state: *ScopeState, id: u32) errno.Error!void {
    (childOf(state, id) catch |err| return errno.narrow(err)).terminate();
}

/// `native.isolate.outcome(id)`: 0 while it runs, then 1 completed, 2 failed, 3 terminated. Reading
/// it after the `done` end closed gives the final value. `BadHandle` for an unknown id.
pub fn outcome(state: *ScopeState, id: u32) errno.Error!u32 {
    const child = childOf(state, id) catch |err| return errno.narrow(err);
    if (!child.finished.load(.acquire)) return 0;
    return switch (child.outcome) {
        .completed => 1,
        .failed => 2,
        .terminated => 3,
    };
}

/// `native.isolate.failure(id)`: the error name of a failed isolate, else undefined. The string is
/// copied for the caller.
pub fn failure(state: *ScopeState, id: u32) errno.Error!?[]const u8 {
    const child = childOf(state, id) catch |err| return errno.narrow(err);
    if (!child.finished.load(.acquire)) return null;
    return child.failure();
}

/// `native.isolate.link()`: for a child isolate `[rx, tx, data]` (its channel ends and the stash id
/// of its data, 0 for none); undefined in the first isolate.
pub fn link(state: *ScopeState) errno.Error!?[3]f64 {
    const given = state.host.link orelse return null;
    return .{ @floatFromInt(given.rx), @floatFromInt(given.tx), @floatFromInt(given.data) };
}
