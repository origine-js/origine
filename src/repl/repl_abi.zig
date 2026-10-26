//! The C ABI of rust/crates/origine_repl as Zig sees it (std only, so `src/gen_contracts.zig` can
//! import it).
//!
//! CONTRACT (docs/contracts.md, surface G): `rust/crates/origine_repl/include/origine_repl.h` is
//! the source of truth. `just gen-contracts` writes `src/repl/repl_abi_check.c` from the
//! declarations below (layouts and prototypes as C `_Static_assert`s/declarations), and
//! `just check-contracts` compiles it against the header with clang: any difference in a struct
//! layout, a field type or a function prototype fails. The Rust side (`origine_repl/src/lib.rs`)
//! is checked against the same header through the generated `header_abi.rs`.
//! Changing the ABI: edit the header, bump `ORIGINE_REPL_ABI_VERSION` and `abi_version` here and
//! in lib.rs, update the declarations here and in lib.rs, then `just gen-contracts`.

pub const abi_version = 1;

/// Opaque: everything one REPL keeps between lines.
pub const Repl = opaque {};
/// Opaque: collects the text of a completion callback.
pub const Sink = opaque {};

pub const CompleteFn = *const fn (ctx: ?*anyopaque, prefix: ?[*]const u8, len: usize, sink: *Sink) callconv(.c) bool;

/// Mirrors `OrigineReplHost` in origine_repl.h.
pub const Host = extern struct {
    ctx: ?*anyopaque,
    complete: CompleteFn,
};

/// `which` of `origine_repl_buffer`.
pub const Buffer = enum(u32) { output, line, source, argument, code, plain, diagnostics };
pub const Command = enum(u32) { source, help, exit, clear, history, again, complete, invalid };
pub const Prepared = enum(u32) { script, async, incomplete, @"error" };
pub const Edit = enum(u32) { @"continue", line, eof, canceled };
pub const append_too_long = 1;

pub extern fn origine_repl_abi_version() u32;
pub extern fn origine_repl_new(colors: bool) ?*Repl;
pub extern fn origine_repl_free(repl: ?*Repl) void;
pub extern fn origine_repl_buffer(repl: *const Repl, which: u32, len: ?*usize) ?[*]const u8;
pub extern fn origine_repl_sink_push(sink: *Sink, bytes: ?[*]const u8, len: usize) void;
pub extern fn origine_repl_command(repl: *Repl, line: ?[*]const u8, len: usize, number: ?*usize) u32;
pub extern fn origine_repl_append(repl: *Repl, line: ?[*]const u8, len: usize) u32;
pub extern fn origine_repl_clear(repl: *Repl) void;
pub extern fn origine_repl_remember(repl: *Repl) void;
pub extern fn origine_repl_recall(repl: *Repl, number: usize) bool;
pub extern fn origine_repl_history_len(repl: *const Repl) usize;
pub extern fn origine_repl_history_get(repl: *const Repl, index: usize, len: ?*usize) ?[*]const u8;
pub extern fn origine_repl_prepare(repl: *Repl) u32;
pub extern fn origine_repl_edit_begin(repl: *Repl, prompt: ?[*]const u8, len: usize) void;
pub extern fn origine_repl_edit_feed(repl: *Repl, byte: u8, width: u32, host: ?*const Host) u32;
pub extern fn origine_repl_edit_timeout(repl: *Repl, width: u32, host: ?*const Host) u32;
pub extern fn origine_repl_edit_eof(repl: *Repl) u32;
pub extern fn origine_repl_edit_in_sequence(repl: *const Repl) bool;
