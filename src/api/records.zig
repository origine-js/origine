//! Loader bridge for the private JS module shared by glue and embedded std modules.
//! No registry functions are published through import.meta.native.
const std = @import("std");
const v8 = @import("@v8");
const eu = @import("@util");
const mod = @import("../managed/module_types.zig");
const glue = @import("glue.zig");
const Host = @import("host.zig").Host;

pub const id = "origine:@internal/records";

pub fn requested(specifier: []const u8) bool {
    return std.mem.eql(u8, specifier, id);
}

pub fn trusted(host: *Host, referrer: []const u8) bool {
    for (host.modules) |module| {
        if (std.mem.eql(u8, module.id, referrer)) return true;
    }
    return false;
}

/// Returned export handles are pinned by the scope until host teardown. The module
/// map copies them before returning from the load callback; snapshots retain only
/// the evaluated module's V8-managed export cells.
pub fn load(host: *Host, request: mod.LoadRequest) !mod.LoadResult {
    const state = for (host.states.items) |candidate| {
        if (!candidate.released and candidate.scope.id == request.scope_id) break candidate;
    } else return error.PermissionDenied;
    const isolate = state.scope.runtime.isolate;
    try glue.prepare(isolate, request.context);
    const bundle = glue.restored(request.context).?;
    const registry_value = bundle.object.getIndex(request.context, glue.records_index) orelse return error.BootstrapFailed;
    const registry = registry_value.toObject(request.context) orelse return error.BootstrapFailed;
    const names = [_][]const u8{ "define", "make", "is", "unwrap", "publish", "internal" };
    const exports = try request.allocator.alloc(mod.Export, names.len);
    for (names, exports) |name, *out| {
        const value = registry.get(request.context, eu.v.str_utf8(isolate, name).name.primitive.value) orelse return error.BootstrapFailed;
        const held: v8.Global.Of(v8.Value) = .new(isolate, value);
        errdefer held.deinit();
        try state.private_exports.append(host.allocator, held);
        out.* = .{ .name = name, .value = held };
    }
    return .{ .exports = exports };
}
