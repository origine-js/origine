//! REPL-owned source and bounded, in-memory history. No terminal or V8 dependency.
const std = @import("std");

pub const Command = union(enum) {
    source,
    help,
    exit,
    clear,
    history,
    again: ?usize,
    complete: []const u8,
    invalid,
};

/// Returned command arguments borrow `line` until the caller consumes them.
pub fn command(line: []const u8) Command {
    const text = std.mem.trim(u8, line, " \r\t");
    if (text.len < 2 or text[0] != '.' or !std.ascii.isAlphabetic(text[1])) return .source;
    var words = std.mem.tokenizeAny(u8, text, " \t");
    const name = words.next().?;
    const known = for ([_][]const u8{ ".again", ".complete", ".help", ".exit", ".clear", ".break", ".history" }) |candidate| {
        if (std.mem.eql(u8, name, candidate)) break true;
    } else false;
    // Preserve dotted property continuations inside multiline JavaScript.
    if (!known) return .source;
    const argument = words.next();
    if (words.next() != null) return .invalid;
    if (std.mem.eql(u8, name, ".again")) {
        const n = if (argument) |arg| std.fmt.parseInt(usize, arg, 10) catch return .invalid else null;
        if (n != null and n.? == 0) return .invalid;
        return .{ .again = n };
    }
    if (std.mem.eql(u8, name, ".complete")) return .{ .complete = argument orelse "" };
    if (argument != null) return .invalid;
    if (std.mem.eql(u8, name, ".help")) return .help;
    if (std.mem.eql(u8, name, ".exit")) return .exit;
    if (std.mem.eql(u8, name, ".clear") or std.mem.eql(u8, name, ".break")) return .clear;
    if (std.mem.eql(u8, name, ".history")) return .history;
    unreachable;
}

pub const Input = struct {
    pub const max_source = 64 * 1024;
    pub const max_history = 100;
    allocator: std.mem.Allocator,
    source: std.ArrayList(u8) = .empty,
    history: std.ArrayList([]const u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Input {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Input) void {
        for (self.history.items) |entry| self.allocator.free(entry);
        self.history.deinit(self.allocator);
        self.source.deinit(self.allocator);
    }

    pub fn clear(self: *Input) void {
        self.source.clearRetainingCapacity();
    }

    /// Copies a line, including a newline separating it from prior lines.
    pub fn append(self: *Input, line: []const u8) !void {
        const separator: usize = if (self.source.items.len == 0) 0 else 1;
        if (separator > max_source - self.source.items.len or
            line.len > max_source - self.source.items.len - separator) return error.InputTooLong;
        try self.source.ensureUnusedCapacity(self.allocator, line.len + separator);
        if (separator != 0) self.source.appendAssumeCapacity('\n');
        self.source.appendSliceAssumeCapacity(line);
    }

    /// Owns a copy; consecutive duplicates share one history entry.
    pub fn remember(self: *Input) !void {
        const entries = self.history.items;
        if (entries.len > 0 and std.mem.eql(u8, entries[entries.len - 1], self.source.items)) return;
        const copy = try self.allocator.dupe(u8, self.source.items);
        errdefer self.allocator.free(copy);
        try self.history.ensureUnusedCapacity(self.allocator, 1);
        if (entries.len == max_history) self.allocator.free(self.history.orderedRemove(0));
        self.history.appendAssumeCapacity(copy);
    }

    /// Copies a one-based history entry (null selects latest) into pending source.
    pub fn recall(self: *Input, number: ?usize) !void {
        const n = number orelse self.history.items.len;
        if (n == 0 or n > self.history.items.len) return error.NoHistoryEntry;
        const entry = self.history.items[n - 1];
        try self.source.ensureTotalCapacity(self.allocator, entry.len);
        self.source.clearRetainingCapacity();
        self.source.appendSliceAssumeCapacity(entry);
    }
};

test "commands preserve decimal JavaScript and validate history arguments" {
    const t = std.testing;
    try t.expect(command(" .help ") == .help);
    try t.expect(command(".5 + .2") == .source);
    try t.expect(command(".map(x => x)") == .source);
    try t.expect(command(".again 0") == .invalid);
    try t.expect(command(".again 1 extra") == .invalid);
    try t.expectEqual(@as(?usize, 2), command(".again 2").again);
    try t.expectEqual(@as(?usize, null), command(".again").again);
    try t.expectEqualStrings("Math.ma", command(".complete Math.ma").complete);
}

test "multiline source and bounded history own their copies" {
    const t = std.testing;
    var input = Input.init(t.allocator);
    defer input.deinit();
    try input.append("({");
    try input.append(" answer: 42 })");
    try input.remember();
    input.clear();
    try input.recall(null);
    try t.expectEqualStrings("({\n answer: 42 })", input.source.items);
    try input.remember();
    try t.expectEqual(@as(usize, 1), input.history.items.len);
    try t.expectError(error.NoHistoryEntry, input.recall(0));
    for (0..Input.max_history + 5) |n| {
        input.clear();
        var buf: [32]u8 = undefined;
        try input.append(try std.fmt.bufPrint(&buf, "{d}", .{n}));
        try input.remember();
    }
    try t.expectEqual(Input.max_history, input.history.items.len);
    try t.expectEqualStrings("5", input.history.items[0]);
    input.clear();
    try input.source.resize(t.allocator, Input.max_source);
    try t.expectError(error.InputTooLong, input.append("x"));
}
