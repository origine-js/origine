//! The C ABI of the Rust `origine_api` crate as Zig sees it (std only, so `src/gen_contracts.zig`
//! can import it).
//!
//! CONTRACT (docs/contracts.md, surfaces B and C): `rust/crates/origine_api/include/origine_api.h`
//! is the source of truth. `just gen-contracts` writes `src/api/api_abi_check.c` from the
//! declarations below and `just check-contracts` compiles it against the header with clang, so a
//! struct layout, field type, constant or prototype that differs is a compile error. The Rust side
//! is checked at compile time against the same header (`origine_api/src/abi_gen.rs`).
//! Changing the ABI: edit the header, update this file, `just gen-contracts`.

/// `origine_api_cfg`: the ceiling and limits handed to the Rust side once per Host.
pub const OriginCfg = extern struct {
    max_runtimes: u32,
    backends_mask: u32,
    default_entries: u32,
    fs_root_fd: i32,
    fs_write: u8,
    fs_async: u8,
};

/// `enum origine_api_side_effect`; `host.zig` maps it to `binding.SideEffect`.
pub const SideEffect = enum(u32) { none = 0, receiver = 1, any = 2 };

/// `enum origine_api_needs`: when a native is installed.
pub const Needs = enum(u32) { none = 0, runtime = 1, async_fs = 2 };

/// `origine_api_callback`: a `v8::FunctionCallback` (the argument is the callback info).
pub const Callback = *const fn (info: *const anyopaque) callconv(.c) void;

/// `origine_api_native`: one guest-visible native of the Rust registry.
pub const Native = extern struct {
    /// `namespace.name`, static.
    path: [*:0]const u8,
    callback: Callback,
    side_effect: u32,
    needs: u32,
};

pub extern fn origine_api_natives_count() usize;
pub extern fn origine_api_natives_get(index: usize, out: *Native) c_int;
pub extern fn origine_api_attach_isolate(isolate: *anyopaque) bool;
pub extern fn origine_api_detach_isolate(isolate: *anyopaque) void;
pub extern fn origine_api_configure(isolate: *anyopaque, cfg: *const OriginCfg) void;
pub extern fn origine_api_poll(isolate: *anyopaque, block: u8, timeout_ns: i64) i64;
pub extern fn origine_api_has_work(isolate: *anyopaque) u8;
pub extern fn origine_api_pollable(isolate: *anyopaque) i64;
pub extern fn origine_api_wake(isolate: *anyopaque) void;
