//! Root of `liborigine_io.a`: the I/O library's C ABI (`oio_*`), always built with
//! ReleaseFast (see build.zig). Programs link the archive; only this root references
//! `c_api`, so the Zig-side `@io` module never exports a second copy of the symbols.
comptime {
    _ = @import("@io").c_api;
}

const std = @import("std");

pub const panic = std.debug.FullPanic(libcPanic);

/// Reports the message on stderr and aborts, like the default handler minus the stack-trace
/// symbolizer (which needs `std.Options.debug_io`, a global `Io.Threaded`, and finds no debug info
/// in a stripped release binary anyway).
fn libcPanic(msg: []const u8, _: ?usize) noreturn {
    _ = std.c.write(2, msg.ptr, msg.len);
    _ = std.c.write(2, "\n", 1);
    std.c.abort();
}

/// No per-thread alternate signal stack: nothing installs a segfault handler, and the default
/// reserves 256 KiB of thread-local storage in every object that links `std.Thread`.
pub const std_options: std.Options = .{ .signal_stack_size = null };

/// `std.debug` and `std.log` write through this; the default is a global `Io.Threaded`, the whole
/// thread pool and every file, socket and process operation, for a few lines of stderr text. Nothing
/// here prints through std (see `managed/stderr.zig`), so a stray use fails instead of linking it.
pub const std_options_debug_io: std.Io = std.Io.failing;
