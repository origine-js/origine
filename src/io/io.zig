//! Public Zig API of the I/O library. The C ABI in c_api.zig wraps the same `Loop`.
pub const op = @import("op.zig");
pub const backend = @import("backend.zig");
/// The C ABI (`oio_*` exports). Programs linking the Rust runtime reference it so the symbols are kept.
pub const c_api = @import("c_api.zig");
pub const Loop = @import("loop.zig").Loop;
pub const Op = op.Op;
pub const Kind = op.Kind;
pub const O = op.O;
pub const Stat = op.Stat;
pub const Fd = op.Fd;
pub const fd_cwd = op.fd_cwd;
pub const Options = backend.Options;
pub const Mode = backend.Mode;
pub const Caps = backend.Caps;

test {
    _ = @import("c_api.zig");
    _ = @import("contract_test.zig");
    _ = @import("tests.zig");
    _ = @import("timers.zig");
}
