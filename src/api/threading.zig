//! `api.host.threading`: what the host offers for running work on several threads.
const std = @import("std");
const errno = @import("errno.zig");
const ScopeState = @import("host.zig").ScopeState;

comptime {
    errno.requireBinding(parallelism);
    errno.requireBinding(identity);
}

/// Logical CPUs this process may run threads on; 1 when the OS does not say.
pub fn parallelism(state: *ScopeState) u32 {
    _ = state;
    const count = std.Thread.getCpuCount() catch return 1;
    return @intCast(@min(count, std.math.maxInt(u32)));
}

/// The number messages from this isolate carry as `event.identity`: 0 in the first isolate, the id
/// `api.isolate.create` returned in a child.
pub fn identity(state: *ScopeState) u32 {
    return if (state.host.link) |link| link.identity else 0;
}
