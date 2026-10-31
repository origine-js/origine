//! Visibility of the host's private modules. `origine:@internal/handles` is the glue's own `handles.js`,
//! adopted by the module map (`ModuleMap.adopt`), so only embedded `origine:` modules may import it;
//! no resolver, loader or guest ever sees it.
const std = @import("std");
const v8 = @import("@v8");
const glue = @import("glue.zig");
const Host = @import("host.zig").Host;

pub fn requested(specifier: []const u8) bool {
    return std.mem.eql(u8, specifier, glue.handles_id);
}

pub fn trusted(host: *Host, referrer: []const u8) bool {
    for (host.modules) |module| {
        if (std.mem.eql(u8, module.id, referrer)) return true;
    }
    return false;
}

/// Makes sure the scope `scope_id` has the glue (and so the module `requested` names) before an import resolves to it.
pub fn prepare(host: *Host, scope_id: usize, ctx: v8.Context) !void {
    const state = for (host.states.items) |candidate| {
        if (!candidate.released and candidate.scope.id == scope_id) break candidate;
    } else return error.PermissionDenied;
    _ = try glue.ensure(state.scope.runtime.isolate, ctx, .{ .scope = state.scope });
}
