//! `api.env`: program arguments and environment variables (read-only).
const std = @import("std");
const Call = @import("binding.zig").Call;
const errno = @import("errno.zig");
const ScopeState = @import("host.zig").ScopeState;

/// Name/value pair the host exposes as an environment variable. Borrowed.
pub const Pair = struct { name: []const u8, value: []const u8 };

comptime {
    errno.requireBinding(list);
}

pub fn args(state: *ScopeState) []const []const u8 {
    return state.host.args;
}

pub fn get(state: *ScopeState, name: []const u8) ?[]const u8 {
    for (state.host.env) |pair| if (std.mem.eql(u8, pair.name, name)) return pair.value;
    return null;
}

pub fn list(state: *ScopeState, call: *Call) errno.Error![]const []const u8 {
    const names = call.allocSlice([]const u8, state.host.env.len);
    for (state.host.env, names) |pair, *out| out.* = pair.name;
    return names;
}
