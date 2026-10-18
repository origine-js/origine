//! Resolver and loader for the init scope: serves the embedded `@engine/std/*`
//! modules and reads every other module from the process working directory.
const std = @import("std");
const module_types = @import("../managed/module_types.zig");
const errno = @import("errno.zig");
const host_mod = @import("host.zig");
const Host = host_mod.Host;

pub const std_io_id = "@engine/std/io";
pub const std_io_source = @embedFile("../js/std_io.js");

/// Modules the init scope can import without touching the file system.
pub const std_modules = [_]struct { id: []const u8, source: []const u8 }{
    .{ .id = std_io_id, .source = std_io_source },
    .{ .id = "@engine/std/errno", .source = errno.module_source },
    .{ .id = "@engine/std/quansync", .source = @embedFile("../js/quansync.js") },
    .{ .id = "@engine/std/fs", .source = @embedFile("../js/std_fs.js") },
    .{ .id = "@engine/std/text", .source = @embedFile("../js/std_text.js") },
};

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
    inline for (std_modules) |module| {
        if (std.mem.eql(u8, request.module_id, module.id)) return .{ .source = module.source };
    }
    const source = try std.Io.Dir.cwd().readFileAlloc(host.io, request.module_id, request.allocator, .unlimited);
    return .{ .source = source };
}
