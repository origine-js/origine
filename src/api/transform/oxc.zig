//! TypeScript/JSX to JavaScript through oxc, via the C ABI of rust/crates/origine_oxc
//! (liborigine_native.a, header include/origine_oxc.h). With `-Dtypescript=false` the Rust
//! library is still linked but built without oxc, so `enabled` is false and nothing here may be
//! called.
const std = @import("std");
const config = @import("origine_config");
const transformer = @import("transformer.zig");

pub const enabled = config.typescript;

const abi = @import("oxc_abi.zig");

pub const abi_version = abi.abi_version;

pub const JsxRuntime = enum(u32) { automatic = 0, classic = 1 };

/// Settings of one transformer. The strings are borrowed for as long as the options are used.
pub const Options = struct {
    jsx_runtime: JsxRuntime = .automatic,
    /// Automatic runtime: the module `<import_source>/jsx-runtime` is imported (default `react`).
    jsx_import_source: ?[]const u8 = null,
    /// Classic runtime: element factory (default `React.createElement`) and fragment.
    jsx_pragma: ?[]const u8 = null,
    jsx_pragma_frag: ?[]const u8 = null,
    jsx_development: bool = false,
    /// Keep imports that only carry types.
    verbatim_imports: bool = false,
    /// Append an inline `//# sourceMappingURL=` comment (V8 ignores it; for external tools).
    inline_source_map: bool = false,
};

const CString = extern struct { ptr: ?[*]const u8, len: usize };

// CONTRACT (docs/contracts.md, surface E): the C structs and prototypes live in oxc_abi.zig.
const COptions = abi.COptions;
const CResult = abi.CResult;
const origine_oxc_abi_version = abi.origine_oxc_abi_version;
const origine_oxc_transform = abi.origine_oxc_transform;
const origine_oxc_result_free = abi.origine_oxc_result_free;

pub const Result = union(enum) {
    /// The JavaScript module text, allocated from the caller's allocator.
    ok: []u8,
    /// Rendered diagnostics (`file:line:col: error: message`, one per line), allocated from the
    /// caller's allocator.
    failure: []u8,
};

/// Transforms `source` (named `filename`, whose extension selects TypeScript, TSX, JSX or JS)
/// with `options`. Borrows all inputs for the call. The returned text is copied into `alloc`
/// (the caller frees it); no memory of the Rust library escapes.
pub fn transform(alloc: std.mem.Allocator, filename: []const u8, source: []const u8, options: Options) error{OutOfMemory}!Result {
    comptime std.debug.assert(enabled);
    var flags: u32 = 0;
    if (options.jsx_development) flags |= 1 << 0;
    if (options.verbatim_imports) flags |= 1 << 1;
    if (options.inline_source_map) flags |= 1 << 2;
    const c_options: COptions = .{
        .jsx_runtime = @intFromEnum(options.jsx_runtime),
        .flags = flags,
        .import_source = if (options.jsx_import_source) |s| s.ptr else null,
        .import_source_len = if (options.jsx_import_source) |s| s.len else 0,
        .pragma = if (options.jsx_pragma) |s| s.ptr else null,
        .pragma_len = if (options.jsx_pragma) |s| s.len else 0,
        .pragma_frag = if (options.jsx_pragma_frag) |s| s.ptr else null,
        .pragma_frag_len = if (options.jsx_pragma_frag) |s| s.len else 0,
    };
    const result = origine_oxc_transform(source.ptr, source.len, filename.ptr, filename.len, &c_options);
    defer origine_oxc_result_free(result);
    if (result.status == 0) {
        return .{ .ok = try alloc.dupe(u8, if (result.code) |p| p[0..result.code_len] else "") };
    }
    return .{ .failure = try alloc.dupe(u8, if (result.diagnostics) |p| p[0..result.diagnostics_len] else "") };
}

/// `Transformer.run` for a `*const Options` in `data`: transforms with oxc. Output (source or
/// diagnostics) is allocated from `request.allocator`.
pub fn run(data: ?*anyopaque, request: transformer.Request) anyerror!transformer.Outcome {
    const options: *const Options = @ptrCast(@alignCast(data.?));
    switch (try transform(request.allocator, request.module_id, request.source, options.*)) {
        .ok => |code| return .{ .source = code },
        .failure => |diagnostics| return .{ .diagnostics = diagnostics },
    }
}

/// True when the linked Rust library speaks `abi_version`.
pub fn compatible() bool {
    return origine_oxc_abi_version() == abi_version;
}
