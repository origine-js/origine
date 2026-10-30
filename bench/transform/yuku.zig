const std = @import("std");
const parser = @import("parser");
// Match Origine's ban on the std.Io threaded diagnostics runtime.
pub const std_options_debug_io: std.Io = std.Io.failing;
// Benchmark-only C ABI. Inputs are borrowed; output is copied to caller-owned storage.
export fn bench_transform(src: [*]const u8, len: usize, kind: u32, out: [*]u8, cap: usize) i64 {
    const allocator = std.heap.c_allocator;
    var tree = parser.parse(allocator, src[0..len], .{
        .lang = switch (kind) {
            0 => .ts,
            1 => .tsx,
            else => .jsx,
        },
        .source_type = .module,
        .preserve_parens = true,
        .comments = .attach,
    }) catch return -3;
    defer tree.deinit();
    if (tree.diagnostics.items.len != 0) return -1;
    const result = parser.codegen.generate(allocator, &tree, .{ .strip = true, .comments = .none }) catch return -3;
    defer result.deinit(allocator);
    if (result.diagnostics.len != 0) return -2;
    if (result.code.len > cap) return -4;
    @memcpy(out[0..result.code.len], result.code);
    return @intCast(result.code.len);
}
