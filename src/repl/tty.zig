//! The terminal side of the line editor: raw mode, reading bytes, writing what the Rust editor
//! (`engine.zig`) asks for. Terminal settings are restored before a line is returned, including
//! EOF, cancellation and errors; evaluation runs in normal mode.
const std = @import("std");
const Engine = @import("engine.zig").Engine;
const engine_mod = @import("engine.zig");
const Helpers = @import("helpers.zig").Helpers;

/// Reads one line with the terminal in raw mode. The result borrows engine storage until its
/// next call; null means end of input. Returns error.Canceled on Ctrl-C.
pub fn readLine(engine: Engine, allocator: std.mem.Allocator, prompt: []const u8, helpers: *const Helpers) !?[]const u8 {
    const original = try std.posix.tcgetattr(0);
    var raw = original;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.iflag.IXON = false;
    raw.iflag.ICRNL = false;
    raw.cc[@backingInt(std.posix.V.MIN)] = 1;
    raw.cc[@backingInt(std.posix.V.TIME)] = 0;
    try std.posix.tcsetattr(0, .NOW, raw);
    defer std.posix.tcsetattr(0, .NOW, original) catch {};

    var completion: Completion = .{ .helpers = helpers, .allocator = allocator };
    const host: engine_mod.Host = .{ .ctx = &completion, .complete = Completion.complete };
    engine.editBegin(prompt);
    try output(engine.buffer(.output));
    while (true) {
        const width = terminalWidth();
        // Inside an escape sequence a pause means the sequence ended (a lone Escape).
        const event = switch (try readByte(if (engine.inSequence()) 40 else null)) {
            .byte => |byte| engine.editFeed(byte, width, &host),
            .timeout => engine.editTimeout(width, &host),
            .eof => engine.editEof(),
        };
        try output(engine.buffer(.output));
        switch (event) {
            .@"continue" => {},
            .line => return engine.buffer(.line),
            .eof => return null,
            .canceled => return error.Canceled,
        }
    }
}

/// Completion requests of the editor, answered from live objects.
const Completion = struct {
    helpers: *const Helpers,
    allocator: std.mem.Allocator,

    fn complete(ctx: ?*anyopaque, prefix: ?[*]const u8, len: usize, sink: *engine_mod.Sink) callconv(.c) bool {
        const self: *const Completion = @ptrCast(@alignCast(ctx.?));
        const matches = self.helpers.completeText(self.allocator, if (prefix) |p| p[0..len] else "") catch return false;
        defer self.allocator.free(matches);
        engine_mod.push(sink, matches.ptr, matches.len);
        return true;
    }
};

fn terminalWidth() u32 {
    var size: std.posix.winsize = .{ .row = 0, .col = 80, .xpixel = 0, .ypixel = 0 };
    _ = std.c.ioctl(1, std.c.T.IOCGWINSZ, &size);
    return if (size.col >= 20) @min(size.col, 4096) else 80;
}

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

const Read = union(enum) { byte: u8, timeout, eof };

/// One byte from stdin. With a timeout, `.timeout` means nothing came in time.
fn readByte(timeout_ms: ?i32) !Read {
    if (timeout_ms) |ms| {
        var fds = [_]std.posix.pollfd{.{ .fd = 0, .events = std.posix.POLL.IN, .revents = 0 }};
        if (try std.posix.poll(&fds, ms) == 0) return .timeout;
    }
    var byte: [1]u8 = undefined;
    if (try std.posix.read(0, &byte) == 0) return .eof;
    return .{ .byte = byte[0] };
}
