//! Unbuffered stderr straight over the vendored lightweight fs (`src/fs_light`), in place of
//! `std.debug.print`: no stderr lock, no terminal-config probing, and one write per `print`
//! call whenever the text fits the buffer.
const std = @import("std");
const fs = @import("../fs_light/fs.zig");

/// Per-call format buffer; text beyond it is cut.
const buffer_len = 512;

/// Formats `fmt` with `args` to stderr and discards write errors, like `std.debug.print`.
pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buffer: [buffer_len]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    out.print(fmt, args) catch {};
    const stderr: fs.File = .{ .handle = if (fs.windows_handles) fs.windows.peb().ProcessParameters.hStdError else fs.posix.STDERR_FILENO };
    stderr.writeAll(out.buffered()) catch {};
}
