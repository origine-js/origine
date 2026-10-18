//! Build-time tool: writes the frozen-intrinsics startup snapshot that origine
//! embeds. Run by build.zig with the output path as the only argument. It uses the
//! same V8 archive and `Engine.init` flags as the shell, which V8 requires for the
//! blob to be accepted.
const std = @import("std");
const m = @import("@managed");
const eu = @import("@util");
const Engine = @import("@engine").Engine;

pub fn main(init: std.process.Init) !void {
    const alloc = eu.alloc;
    const args = try init.minimal.args.toSlice(alloc);
    defer alloc.free(args);
    if (args.len != 2) return error.UsageOutputPath;
    var io_runtime: std.Io.Threaded = .init(alloc, .{});
    defer io_runtime.deinit();
    var engine = Engine.init(.{});
    defer engine.deinit();
    const blob = try m.snapshot.create(std.heap.page_allocator);
    defer std.heap.page_allocator.free(blob);
    try std.Io.Dir.cwd().writeFile(io_runtime.io(), .{ .sub_path = args[1], .data = blob });
}
