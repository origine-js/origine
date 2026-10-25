//! Managed JavaScript REPL: evaluation and continuation probes (`eval`), REPL-only
//! V8 helpers (`Helpers`), pending input and history (`input`), line editing
//! (`terminal`) and the loop that ties them together (`run`).
const std = @import("std");

pub const input = @import("repl/input.zig");
pub const terminal = @import("repl/terminal.zig");
pub const display = @import("repl/display.zig");
pub const Helpers = @import("repl/helpers.zig").Helpers;
pub const sourceForEval = @import("repl/eval.zig").sourceForEval;
pub const eval = @import("repl/eval.zig").eval;
pub const incomplete = @import("repl/eval.zig").incomplete;
pub const Options = @import("repl/session.zig").Options;
pub const run = @import("repl/session.zig").run;

/// Whether stdin/stdout are a capable terminal (not piped, `TERM=dumb` excluded).
pub fn isInteractive(io: std.Io, environ: *const std.process.Environ.Map) bool {
    return (std.Io.File.stdin().isTty(io) catch false) and
        (std.Io.File.stdout().isTty(io) catch false) and
        !std.mem.eql(u8, environ.get("TERM") orelse "", "dumb");
}
