//! Build-time tool: writes the frozen-intrinsics and prepared-API snapshot that origine
//! embeds. Run by build.zig with the output path and, to LZ4-compress the blob (`lib/lz4`), `lz4`. It uses the
//! same V8 archive and `Engine.init` flags as the shell, which V8 requires for the
//! blob to be accepted.
const std = @import("std");
const m = @import("@managed");
const eu = @import("@util");
const v8 = @import("@v8");
const Engine = @import("@engine").Engine;
const lz4 = @import("@lz4");
const build_options = @import("build_options");

pub fn main(init: std.process.Init.Minimal) !void {
    const alloc = eu.alloc;
    const args = try init.args.toSlice(alloc);
    defer alloc.free(args);
    if (args.len < 2 or args.len > 3) return error.UsageOutputPath;
    const compress = args.len == 3;
    if (compress and !std.mem.eql(u8, args[2], "lz4")) return error.UsageUnknownMode;
    // A fixed seed plus predictable mode makes the snapshot reproducible, so an unchanged
    // rebuild reuses the embedded blob. V8 freezes its flags during initialization.
    // `--predictable` alone still sizes the young generation and grows the heap from
    // measured allocation throughput, so a slower run (a cold binary, a loaded machine)
    // collects at other points and serializes a different heap layout;
    // `--predictable-gc-schedule` fixes that schedule.
    if (build_options.snapshot_seeded) {
        var flags_buf: [128]u8 = undefined;
        const flags = try std.fmt.bufPrint(&flags_buf, "--random-seed={d} --predictable --predictable-gc-schedule", .{build_options.snapshot_seed});
        v8.V8.setFlagsFromString(flags);
    }

    var engine = Engine.init(.{});
    defer engine.deinit();
    const blob = try m.snapshot.create(std.heap.page_allocator);
    defer std.heap.page_allocator.free(blob);
    if (!compress) return m.sys.Dir.cwd().writeFile(.{ .sub_path = args[1], .data = blob });
    const packed_blob = try lz4.pack(alloc, blob);
    defer alloc.free(packed_blob);
    try m.sys.Dir.cwd().writeFile(.{ .sub_path = args[1], .data = packed_blob });
}
