const std = @import("std");
const t = std.testing;
const m = @import("@managed");
const sys = m.sys;

fn root(tmp: *t.TmpDir) sys.Dir {
    return .{ .handle = tmp.dir.handle };
}

test "sys: directories, files and the errors the host maps" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir = root(&tmp);
    try dir.createDirPath("a/b/c");
    try dir.createDirPath("a/b/c");
    try dir.writeFile(.{ .sub_path = "a/b/c/x.txt", .data = "hello" });
    const file = try dir.openFile("a/b/c/x.txt", .{});
    defer file.close();
    var buffer: [8]u8 = undefined;
    try t.expectEqual(@as(usize, 5), try file.readPositionalAll(&buffer, 0));
    try t.expectEqualStrings("hello", buffer[0..5]);
    try t.expectEqual(@as(usize, 0), try file.readPositional(&.{&buffer}, 5));
    try t.expectError(error.FileNotFound, dir.statFile("a/missing", .{}));
    try t.expectError(error.FileNotFound, dir.statFile("a/b/c/x.txt/y", .{}));
    try t.expectError(error.IsDir, dir.openFile("a", .{ .allow_directory = false }));
    try t.expectError(error.DirNotEmpty, dir.deleteDir("a/b"));
    try t.expectError(error.PathAlreadyExists, dir.createDir("a", .default_dir));
    var it = dir.iterate();
    const only = (try it.next()).?;
    try t.expectEqualStrings("a", only.name);
    try t.expectEqual(sys.File.Kind.directory, only.kind);
    try t.expect((try it.next()) == null);
    try dir.deleteTree("a");
    try dir.deleteTree("a");
    try t.expectError(error.FileNotFound, dir.statFile("a", .{}));
}

test "sys: exclusive create, rename, positional writes and truncation" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir = root(&tmp);
    const file = try dir.createFile("f", .{ .read = true, .exclusive = true });
    try t.expectError(error.PathAlreadyExists, dir.createFile("f", .{ .exclusive = true }));
    try file.writePositionalAll("world", 3);
    try t.expectEqual(@as(u64, 8), (try file.stat()).size);
    try file.setLength(5);
    try file.sync();
    file.close();
    try dir.rename("f", dir, "g");
    try t.expectError(error.FileNotFound, dir.statFile("f", .{}));
    const bytes = try dir.readFileAlloc("g", t.allocator, .limited(16));
    defer t.allocator.free(bytes);
    try t.expectEqualSlices(u8, "\x00\x00\x00wo", bytes);
    try t.expectError(error.StreamTooLong, dir.readFileAlloc("g", t.allocator, .limited(5)));
    try t.expectEqual(sys.File.Kind.sym_link, blk: {
        try sys.light.posix.symlinkat("g", dir.handle, "link");
        break :blk (try dir.statFile("link", .{ .follow_symlinks = false })).kind;
    });
}
