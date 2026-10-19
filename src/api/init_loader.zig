//! Resolver and loader for the init scope: serves the embedded `origine:@std/*`
//! modules and reads every other module from the process working directory.
const std = @import("std");
const module_types = @import("../managed/module_types.zig");
const binding = @import("binding.zig");
const origine_modules = @import("origine_modules.zig");
const host_mod = @import("host.zig");
const Host = host_mod.Host;
const ScopeState = host_mod.ScopeState;

/// Modules the init scope can import without touching the file system by default; a
/// Host serves `Config.modules`, which defaults to this table.
pub const std_modules = origine_modules.all;

/// Relative specifiers (`./`, `../`) resolve against the referrer's directory;
/// everything else is used as written.
pub fn resolve(data: ?*anyopaque, request: module_types.ResolveRequest) anyerror![]const u8 {
    _ = data;
    const spec = request.specifier;
    if (!(std.mem.startsWith(u8, spec, "./") or std.mem.startsWith(u8, spec, "../"))) return request.allocator.dupe(u8, spec);
    const base = std.fs.path.dirnamePosix(request.referrer) orelse "";
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(request.allocator);
    inline for (.{ base, spec }) |chunk| {
        var it = std.mem.splitScalar(u8, chunk, '/');
        while (it.next()) |part| {
            if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
            if (std.mem.eql(u8, part, "..")) {
                if (parts.items.len == 0) return error.InvalidPath;
                _ = parts.pop();
            } else try parts.append(request.allocator, part);
        }
    }
    return std.mem.join(request.allocator, "/", parts.items);
}

pub fn load(data: ?*anyopaque, request: module_types.LoadRequest) anyerror!module_types.LoadResult {
    const host: *Host = @ptrCast(@alignCast(data.?));
    for (host.modules) |module| {
        if (std.mem.eql(u8, request.module_id, module.id)) return .{ .source = module.source };
    }
    // The `origine:` namespace belongs to the embedded modules: a working-directory file can
    // never take such an id (and so never receives the natives `meta` hands to std modules).
    if (std.mem.startsWith(u8, request.module_id, module_types.origine_prefix)) return error.FileNotFound;
    const source = try std.Io.Dir.cwd().readFileAlloc(host.io, request.module_id, request.allocator, .unlimited);
    return .{ .source = source };
}

/// Fills `import.meta.native` for the embedded modules that declare `bindings`; every
/// other module, user code included, keeps a bare `import.meta`. The match is on the exact
/// embedded id, which `load` guarantees no other source can carry. The natives are
/// deep-frozen and hold no authority; the receiving module is expected to capture and
/// delete the property. Best effort: on any failure `native` stays absent and the module
/// falls back to its JS implementation. Borrows `request` for the call.
pub fn meta(data: ?*anyopaque, request: module_types.MetaRequest) void {
    const host: *Host = @ptrCast(@alignCast(data.?));
    for (host.modules) |module| {
        const bindings = module.bindings orelse continue;
        if (!std.mem.eql(u8, request.module_id, module.id)) continue;
        const state: *ScopeState = for (host.states.items) |candidate| {
            if (candidate.scope.id == request.scope_id) break candidate;
        } else return;
        const env: binding.Env = .{ .isolate = state.scope.runtime.isolate, .ctx = request.context };
        const owned = state.moduleState(module) catch return;
        const natives = bindings.build(env, state, owned) catch return;
        state.scope.hardenLocal(natives.value) catch return;
        binding.set(env, request.meta, "native", natives) catch return;
        return;
    }
}
