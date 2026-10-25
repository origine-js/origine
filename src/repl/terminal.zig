//! Interactive line editing. Terminal settings are restored before returning a
//! line, including EOF, cancellation and errors; evaluation runs in normal mode.
const std = @import("std");
const Input = @import("input.zig").Input;
const bun = @import("bun_completion.zig");

pub const Editor = struct {
    allocator: std.mem.Allocator,
    line: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    colors: bool = true,
    suggestion: std.ArrayList(u8) = .empty,
    draft: std.ArrayList(u8) = .empty,
    history_position: usize = 0,

    pub fn deinit(self: *Editor) void {
        self.line.deinit(self.allocator);
        self.suggestion.deinit(self.allocator);
        self.draft.deinit(self.allocator);
    }

    pub fn read(self: *Editor, prompt: []const u8, helpers: anytype, pending: *const Input) !?[]const u8 {
        const original = try std.posix.tcgetattr(0);
        var raw = original;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.iflag.IXON = false;
        raw.cc[@backingInt(std.posix.V.MIN)] = 1;
        raw.cc[@backingInt(std.posix.V.TIME)] = 0;
        try std.posix.tcsetattr(0, .NOW, raw);
        defer std.posix.tcsetattr(0, .NOW, original) catch {};
        self.line.clearRetainingCapacity();
        self.cursor = 0;
        self.suggestion.clearRetainingCapacity();
        self.draft.clearRetainingCapacity();
        self.history_position = pending.history.items.len;
        try output(prompt);
        var escape: enum { none, esc, csi, delete } = .none;
        while (true) {
            var byte: [1]u8 = undefined;
            if (try std.posix.read(0, &byte) == 0) return null;
            const ch = byte[0];
            if (escape != .none) {
                switch (escape) {
                    .esc => escape = if (ch == '[' or ch == 'O') .csi else .none,
                    .csi => {
                        escape = .none;
                        switch (ch) {
                            'D' => self.cursor = previous(self.line.items, self.cursor),
                            'C' => if (self.cursor != self.line.items.len or !try self.acceptSuggestion()) {
                                self.cursor = next(self.line.items, self.cursor);
                            },
                            'A' => try self.history(pending, true),
                            'B' => try self.history(pending, false),
                            'H' => self.cursor = 0,
                            'F' => {
                                _ = try self.acceptSuggestion();
                                self.cursor = self.line.items.len;
                            },
                            '3' => escape = .delete,
                            else => {},
                        }
                    },
                    .delete => {
                        if (ch == '~') self.delete();
                        escape = .none;
                    },
                    .none => unreachable,
                }
            } else switch (ch) {
                27 => {
                    escape = .esc;
                    continue;
                },
                '\r', '\n' => {
                    self.suggestion.clearRetainingCapacity();
                    try self.redraw(prompt, helpers);
                    try output("\n");
                    return self.line.items;
                },
                3 => {
                    try output("^C\n");
                    return error.Canceled;
                },
                4 => {
                    if (self.line.items.len == 0) {
                        try output("\n");
                        return null;
                    }
                    self.delete();
                },
                1 => self.cursor = 0,
                5 => {
                    _ = try self.acceptSuggestion();
                    self.cursor = self.line.items.len;
                },
                2 => self.cursor = previous(self.line.items, self.cursor),
                6 => if (self.cursor != self.line.items.len or !try self.acceptSuggestion()) {
                    self.cursor = next(self.line.items, self.cursor);
                },
                16 => try self.history(pending, true),
                14 => try self.history(pending, false),
                11 => self.line.shrinkRetainingCapacity(self.cursor),
                21 => {
                    std.mem.copyForwards(u8, self.line.items, self.line.items[self.cursor..]);
                    self.line.items.len -= self.cursor;
                    self.cursor = 0;
                },
                8, 127 => {
                    const before = previous(self.line.items, self.cursor);
                    if (before < self.cursor) {
                        const removed = self.cursor - before;
                        std.mem.copyForwards(u8, self.line.items[before..], self.line.items[self.cursor..]);
                        self.line.items.len -= removed;
                        self.cursor = before;
                    }
                },
                '\t' => if (!try self.acceptSuggestion()) {
                    if (bun.insideText(&.{ pending.source.items, self.line.items[0..self.cursor] })) {
                        try self.insert("  ");
                    } else try self.complete(prompt, helpers);
                },
                32...126, 128...255 => try self.insert(&byte),
                else => continue,
            }
            try self.updateSuggestion(helpers, pending);
            try self.redraw(prompt, helpers);
        }
    }

    fn insert(self: *Editor, text: []const u8) !void {
        if (text.len > Input.max_source - self.line.items.len) return;
        try self.line.insertSlice(self.allocator, self.cursor, text);
        self.cursor += text.len;
    }

    fn delete(self: *Editor) void {
        const end = next(self.line.items, self.cursor);
        std.mem.copyForwards(u8, self.line.items[self.cursor..], self.line.items[end..]);
        self.line.items.len -= end - self.cursor;
    }

    fn history(self: *Editor, pending: *const Input, backwards: bool) !void {
        const entries = pending.history.items;
        if (backwards) {
            if (self.history_position == 0) return;
            if (self.history_position == entries.len) {
                self.draft.clearRetainingCapacity();
                try self.draft.appendSlice(self.allocator, self.line.items);
            }
            self.history_position -= 1;
        } else {
            if (self.history_position >= entries.len) return;
            self.history_position += 1;
        }
        self.line.clearRetainingCapacity();
        try self.line.appendSlice(self.allocator, if (self.history_position == entries.len) self.draft.items else entries[self.history_position]);
        self.cursor = self.line.items.len;
    }

    fn updateSuggestion(self: *Editor, helpers: anytype, pending: *const Input) !void {
        self.suggestion.clearRetainingCapacity();
        if (!self.colors or self.cursor != self.line.items.len or self.cursor == 0 or self.line.items[0] == '.') return;
        if (bun.insideText(&.{ pending.source.items, self.line.items })) return;
        const start = completionStart(self.line.items, self.cursor) orelse return;
        const prefix = self.line.items[start..self.cursor];
        const matches = helpers.completeText(self.allocator, prefix) catch return;
        defer self.allocator.free(matches);
        try self.suggestion.appendSlice(self.allocator, bun.suggestion(matches, prefix));
    }

    fn acceptSuggestion(self: *Editor) !bool {
        if (self.cursor != self.line.items.len or self.suggestion.items.len == 0) return false;
        try self.insert(self.suggestion.items);
        self.suggestion.clearRetainingCapacity();
        return true;
    }

    fn complete(self: *Editor, prompt: []const u8, helpers: anytype) !void {
        if (self.cursor < self.line.items.len and bun.word(self.line.items[self.cursor])) return;
        const start = completionStart(self.line.items, self.cursor) orelse {
            try self.insert("  ");
            return;
        };
        const prefix = self.line.items[start..self.cursor];
        const matches = helpers.completeText(self.allocator, prefix) catch {
            try output("\x07");
            return;
        };
        defer self.allocator.free(matches);
        if (matches.len == 0 or matches[0] == '(' or std.mem.startsWith(u8, matches, "Use ")) {
            try output("\x07");
            return;
        }
        const common = commonPrefix(matches);
        if (common.len > prefix.len) {
            try self.insert(common[prefix.len..]);
        } else {
            try output("\n");
            try output(matches);
            try output("\n");
            try output(prompt);
        }
    }

    // A horizontally scrolling viewport keeps redraws on one terminal row,
    // including long inputs. Reserve space for wide UTF-8 characters.
    fn redraw(self: *Editor, prompt: []const u8, helpers: anytype) !void {
        var size: std.posix.winsize = .{ .row = 0, .col = 80, .xpixel = 0, .ypixel = 0 };
        _ = std.c.ioctl(1, std.c.T.IOCGWINSZ, &size);
        const width: usize = if (size.col >= 20) @min(size.col, 4096) else 80;
        const budget = width - prompt.len - 2;
        const reserve = @min(self.suggestion.items.len, budget / 3);
        var start = self.cursor;
        var count: usize = 0;
        while (start > 0) {
            const before = previous(self.line.items, start);
            const cells: usize = if (self.line.items[before] >= 0xe0) 2 else 1;
            if (count + cells > budget - reserve) break;
            count += cells;
            start = before;
        }
        var end = self.cursor;
        while (end < self.line.items.len) {
            const cells: usize = if (self.line.items[end] >= 0xe0) 2 else 1;
            if (count + cells > budget) break;
            count += cells;
            end = next(self.line.items, end);
        }
        try output("\r\x1b[2K");
        try output(prompt);
        if (start != 0) try output("<");
        const before = try helpers.renderText(self.allocator, if (self.colors) "highlight" else "line", self.line.items[start..self.cursor]);
        defer self.allocator.free(before);
        try output(before);
        try output("\x1b[s");
        const after = try helpers.renderText(self.allocator, if (self.colors) "highlight" else "line", self.line.items[self.cursor..end]);
        defer self.allocator.free(after);
        try output(after);
        if (self.colors and self.cursor == self.line.items.len and self.suggestion.items.len > 0 and count < budget) {
            try output("\x1b[2m");
            try output(self.suggestion.items[0..@min(self.suggestion.items.len, budget - count)]);
            try output("\x1b[0m");
        }
        try output("\x1b[u");
    }
};

fn output(text: []const u8) !void {
    var rest = text;
    while (rest.len > 0) {
        const n = std.c.write(1, rest.ptr, rest.len);
        if (n < 0) {
            if (std.posix.errno(n) == .INTR) continue;
            return error.WriteFailed;
        }
        if (n == 0) return error.WriteFailed;
        rest = rest[@intCast(n)..];
    }
}

fn previous(text: []const u8, cursor: usize) usize {
    if (cursor == 0) return 0;
    var at = cursor - 1;
    while (at > 0 and text[at] & 0xc0 == 0x80) at -= 1;
    return at;
}

fn next(text: []const u8, cursor: usize) usize {
    if (cursor == text.len) return cursor;
    var at = cursor + 1;
    while (at < text.len and text[at] & 0xc0 == 0x80) at += 1;
    return at;
}

/// Returns a simple identifier/property suffix ending at the cursor.
fn completionStart(text: []const u8, cursor: usize) ?usize {
    if (cursor > 0 and text[0] == '.') {
        const command = for (text[1..cursor]) |ch| {
            if (!std.ascii.isAlphabetic(ch)) break false;
        } else true;
        if (command) return 0;
    }
    return bun.start(text, cursor);
}

fn commonPrefix(matches: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, matches, '\n');
    var common = lines.next() orelse return "";
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "…")) return ""; // truncated results cannot establish a safe common prefix
        var n: usize = 0;
        while (n < @min(common.len, line.len) and common[n] == line[n]) : (n += 1) {}
        common = common[0..n];
    }
    return common;
}

test "completion inserts at cursor and preserves suffix; common matches stay safe" {
    const t = std.testing;
    try t.expectEqual(@as(?usize, 2), completionStart("( Math.ma(1))", 9));
    try t.expectEqual(@as(?usize, null), completionStart("  ", 2));
    try t.expectEqualStrings("Math.max", commonPrefix("Math.max"));
    try t.expectEqualStrings("Object.getOwnProperty", commonPrefix("Object.getOwnPropertyNames\nObject.getOwnPropertySymbols"));
    try t.expectEqualStrings("", commonPrefix("Math.max\n…"));
    var editor: Editor = .{ .allocator = t.allocator };
    defer editor.deinit();
    try editor.insert("Math.ma(1)");
    editor.cursor = 7;
    try editor.insert("x");
    try t.expectEqualStrings("Math.max(1)", editor.line.items);
    editor.delete();
    try t.expectEqualStrings("Math.max1)", editor.line.items);
}

test "editing moves across UTF-8 codepoints" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 1), previous("a貓b", 4));
    try t.expectEqual(@as(usize, 4), next("a貓b", 1));
}

test {
    _ = bun;
}
