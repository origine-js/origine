const std = @import("std");
const fs = @import("fs.zig");
test "x" {
    _ = fs.Dir;
    _ = fs.File;
    const d = fs.cwd();
    _ = d.statFile("a") catch {};
    _ = d.openFile("a", .{}) catch {};
    _ = d.deleteTree("a") catch {};
    var it = d.iterate();
    _ = it.next() catch {};
    _ = d.makePath("a") catch {};
}
