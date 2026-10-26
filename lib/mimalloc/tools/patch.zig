//! Build tool: copies a source tree and applies unified diffs (as `diff -u`/`git diff` write
//! them, one path component stripped) to the copy.
//!
//!   patch <source-dir> <output-dir> <patch>...
//!
//! Hunks are placed by their context lines, searching forward from where the previous hunk
//! ended, so patches survive line-number drift; a hunk that does not match exactly fails the
//! build and names the file and hunk.
const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) {
        std.debug.print("usage: patch <source-dir> <output-dir> <patch>...\n", .{});
        std.process.exit(2);
    }
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, args[2]);
    var source = try cwd.openDir(io, args[1], .{ .iterate = true });
    defer source.close(io);
    var out = try cwd.openDir(io, args[2], .{});
    defer out.close(io);
    try copyTree(arena, io, source, out);
    for (args[3..]) |patch_path| {
        const text = try cwd.readFileAlloc(io, patch_path, arena, .limited(1 << 24));
        applyPatch(arena, io, out, text) catch |err| {
            std.debug.print("{s}: {t}\n", .{ patch_path, err });
            std.process.exit(1);
        };
    }
}

/// Copies every file and directory of `source` into `out`, files writable.
fn copyTree(gpa: std.mem.Allocator, io: Io, source: Io.Dir, out: Io.Dir) !void {
    var walker = try source.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| switch (entry.kind) {
        .directory => try out.createDirPath(io, entry.path),
        .file => try source.copyFile(entry.path, out, entry.path, io, .{ .permissions = .default_file, .make_path = true }),
        else => {},
    };
}

const PatchError = error{ BadPatch, HunkDoesNotApply } || std.mem.Allocator.Error || Io.Dir.ReadFileAllocError || Io.Dir.WriteFileError;

/// Applies every file section of the unified diff `text` to the files under `root`.
fn applyPatch(gpa: std.mem.Allocator, io: Io, root: Io.Dir, text: []const u8) PatchError!void {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| try lines.append(gpa, line);

    var i: usize = 0;
    while (i < lines.items.len) {
        if (!std.mem.startsWith(u8, lines.items[i], "--- ")) {
            i += 1;
            continue;
        }
        if (i + 1 >= lines.items.len or !std.mem.startsWith(u8, lines.items[i + 1], "+++ ")) return error.BadPatch;
        const path = stripComponent(lines.items[i + 1][4..]) orelse return error.BadPatch;
        i += 2;

        const original = try root.readFileAlloc(io, path, gpa, .limited(1 << 26));
        var old: std.ArrayList([]const u8) = .empty;
        var old_it = std.mem.splitScalar(u8, original, '\n');
        while (old_it.next()) |line| try old.append(gpa, line);

        var result: std.ArrayList([]const u8) = .empty;
        var cursor: usize = 0;
        while (i < lines.items.len and std.mem.startsWith(u8, lines.items[i], "@@")) {
            i += 1;
            var before: std.ArrayList([]const u8) = .empty;
            var after: std.ArrayList([]const u8) = .empty;
            while (i < lines.items.len) : (i += 1) {
                const line = lines.items[i];
                if (line.len == 0) {
                    // The empty string after the patch's final newline ends the last hunk;
                    // elsewhere it is a blank context line whose space was trimmed.
                    if (i + 1 >= lines.items.len) break;
                    try before.append(gpa, "");
                    try after.append(gpa, "");
                    continue;
                }
                // The next file's header looks like a removed line.
                if (std.mem.startsWith(u8, line, "--- ") and i + 1 < lines.items.len and
                    std.mem.startsWith(u8, lines.items[i + 1], "+++ ")) break;
                switch (line[0]) {
                    ' ' => {
                        try before.append(gpa, line[1..]);
                        try after.append(gpa, line[1..]);
                    },
                    '-' => try before.append(gpa, line[1..]),
                    '+' => try after.append(gpa, line[1..]),
                    '\\' => {},
                    else => break,
                }
            }
            const at = find(old.items, cursor, before.items) orelse {
                std.debug.print("{s}: hunk does not apply near line {d}\n", .{ path, cursor + 1 });
                return error.HunkDoesNotApply;
            };
            try result.appendSlice(gpa, old.items[cursor..at]);
            try result.appendSlice(gpa, after.items);
            cursor = at + before.items.len;
        }
        try result.appendSlice(gpa, old.items[cursor..]);

        const patched = try std.mem.join(gpa, "\n", result.items);
        try root.writeFile(io, .{ .sub_path = path, .data = patched });
    }
}

/// `a/src/x.c` or `b/src/x.c` -> `src/x.c`, ignoring a trailing tab-separated timestamp.
fn stripComponent(header: []const u8) ?[]const u8 {
    const name = if (std.mem.indexOfScalar(u8, header, '\t')) |tab| header[0..tab] else header;
    const slash = std.mem.indexOfScalar(u8, name, '/') orelse return null;
    return name[slash + 1 ..];
}

/// The first index at or after `from` where `needle` occurs in `haystack`.
fn find(haystack: []const []const u8, from: usize, needle: []const []const u8) ?usize {
    if (needle.len == 0) return from;
    if (haystack.len < needle.len) return null;
    var at = from;
    while (at + needle.len <= haystack.len) : (at += 1) {
        for (needle, haystack[at..][0..needle.len]) |want, got| {
            if (!std.mem.eql(u8, want, got)) break;
        } else return at;
    }
    return null;
}

test "hunks apply by context and keep the file's end" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const old = [_][]const u8{ "a", "b", "c", "d", "" };
    try std.testing.expectEqual(@as(?usize, 1), find(&old, 0, &.{ "b", "c" }));
    try std.testing.expectEqual(@as(?usize, null), find(&old, 2, &.{ "b", "c" }));
    try std.testing.expectEqualStrings("src/x.c", stripComponent("b/src/x.c\t2026-01-01").?);
}
