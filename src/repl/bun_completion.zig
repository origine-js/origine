//! Adapted from Bun's native REPL completion context/string handling at
//! oven-sh/bun 5c6d4e24cd185d5bef8d98e7f1f1e3ef10ac163f, src/runtime/cli/repl.rs.
//! Copyright Bun contributors. MIT license; see BUN-NOTICE.md.
const std = @import("std");

pub fn word(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '$' or ch >= 0x80;
}

/// Port of parse_completion_context: do not suggest globals after `foo().`,
/// and treat spread (`...args`) separately from member access.
pub fn start(line: []const u8, cursor: usize) ?usize {
    var i = cursor;
    while (i > 0 and word(line[i - 1])) i -= 1;
    if (!memberDot(line, i)) return if (i == cursor) null else i;
    i -= 1;
    while (true) {
        const end = i;
        while (i > 0 and word(line[i - 1])) i -= 1;
        if (i == end) return null;
        if (!memberDot(line, i)) break;
        i -= 1;
    }
    return i;
}

fn memberDot(line: []const u8, end: usize) bool {
    return end >= 1 and line[end - 1] == '.' and (end < 2 or line[end - 2] != '.');
}

/// Port of ends_inside_string, with comment handling added for Origine.
/// Parts borrow pending multiline source and the current line up to the cursor.
pub fn insideText(parts: []const []const u8) bool {
    var quote: u8 = 0;
    var holes: [128]usize = undefined;
    var depth: usize = 0;
    var block_comment = false;
    for (parts) |part| {
        var line_comment = false;
        var i: usize = 0;
        while (i < part.len) {
            const ch = part[i];
            i += 1;
            if (line_comment) {
                if (ch == '\n') line_comment = false;
            } else if (block_comment) {
                if (ch == '*' and i < part.len and part[i] == '/') {
                    block_comment = false;
                    i += 1;
                }
            } else if (quote != 0) {
                if (ch == '\\') {
                    i += 1;
                } else if (ch == '$' and quote == '`' and i < part.len and part[i] == '{') {
                    if (depth == holes.len) return true;
                    holes[depth] = 1;
                    depth += 1;
                    quote = 0;
                    i += 1;
                } else if (ch == quote) {
                    quote = 0;
                }
            } else switch (ch) {
                '\'', '"', '`' => quote = ch,
                '/' => if (i < part.len) {
                    if (part[i] == '/') {
                        line_comment = true;
                        i += 1;
                    } else if (part[i] == '*') {
                        block_comment = true;
                        i += 1;
                    }
                },
                '{' => if (depth > 0) {
                    holes[depth - 1] += 1;
                },
                '}' => if (depth > 0) {
                    holes[depth - 1] -= 1;
                    if (holes[depth - 1] == 0) {
                        depth -= 1;
                        quote = '`';
                    }
                },
                else => {},
            }
        }
        if (line_comment) return true;
    }
    return quote != 0 or block_comment;
}

/// Port of update_suggestion: shortest matching identifier wins, not the
/// longest shared prefix. Returned suffix borrows the completion list.
pub fn suggestion(matches: []const u8, prefix: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, matches, '\n');
    var best: ?[]const u8 = null;
    while (lines.next()) |line| {
        if (line.len <= prefix.len or !std.mem.startsWith(u8, line, prefix)) continue;
        if (best == null or line.len < best.?.len) best = line;
    }
    return if (best) |name| name[prefix.len..] else "";
}

test "Bun completion contexts and string/template suppression" {
    const t = std.testing;
    try t.expectEqual(@as(?usize, 0), start("Math.ma", 7));
    try t.expectEqual(@as(?usize, null), start("foo().ba", 8));
    try t.expectEqual(@as(?usize, 4), start("[...args", 8));
    try t.expect(insideText(&.{"'Math.ma"}));
    try t.expect(insideText(&.{"// Math.ma"}));
    try t.expect(!insideText(&.{"`hello ${Math.ma"}));
    try t.expect(insideText(&.{"`hello ${1} Math.ma"}));
    try t.expectEqualStrings("ax", suggestion("Math.max\nMath.min", "Math.m"));
}
