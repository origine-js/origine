//! Managed JavaScript REPL: the Rust engine (`engine`: parsing, pending input, history and the
//! line editor), terminal I/O (`tty`), evaluation (`eval`), REPL-only V8 helpers (`Helpers`) and
//! the loop that ties them together (`run`).
const std = @import("std");
const sys = @import("@managed").sys;

pub const engine = @import("repl/engine.zig");
pub const Engine = engine.Engine;
pub const display = @import("repl/display.zig");
pub const Helpers = @import("repl/helpers.zig").Helpers;
pub const eval = @import("repl/eval.zig").eval;
pub const Options = @import("repl/session.zig").Options;
pub const run = @import("repl/session.zig").run;

/// Whether stdin/stdout are a capable terminal (not piped, `TERM=dumb` excluded).
pub fn isInteractive(environ: *const std.process.Environ.Map) bool {
    return (sys.File.stdin().isTty() catch false) and
        (sys.File.stdout().isTty() catch false) and
        !std.mem.eql(u8, environ.get("TERM") orelse "", "dumb");
}
