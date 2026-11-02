//! V8 (lib/v8_zig) as the root build sees it: the option block and the dependency call, so the
//! root only forwards its `-Dv8_*` options. Every field maps to an option of that package.

const std = @import("std");

/// How the V8 package embeds ICU's data (lib/v8_zig/build/icu.build.zig).
pub const IcuMode = enum { compressed, raw };

pub const Options = struct {
    target: std.Build.ResolvedTarget,
    v8_debug: bool,
    v8_sandbox: bool,
    v8_memory_corruption_api: bool,
    builtin_pgo: bool,
    v8_icu: IcuMode,
    prebuilt: ?[]const u8,
    clang_bin: []const u8,
    cache_root: []const u8,
};

/// Borrows b and options, including nested path strings, through build teardown. Returns a
/// build-owned dependency valid through teardown; retains no runtime resources.
pub fn dependency(b: *std.Build, options: Options, link_native: bool) *std.Build.Dependency {
    return if (options.prebuilt) |path| b.dependency("v8", .{
        .target = options.target,
        .optimize = .fast,
        .v8_debug = options.v8_debug,
        .v8_sandbox = options.v8_sandbox,
        .link_native = link_native,
        .prebuilt_v8_path = path,
        .v8_clang_dir = options.clang_bin,
    }) else b.dependency("v8", .{
        .target = options.target,
        .optimize = .fast,
        .v8_debug = options.v8_debug,
        .v8_sandbox = options.v8_sandbox,
        .v8_memory_corruption_api = options.v8_memory_corruption_api,
        .link_native = link_native,
        .cache_root = options.cache_root,
        .builtin_pgo = options.builtin_pgo,
        .v8_icu = options.v8_icu,
        .v8_clang_dir = options.clang_bin,
    });
}

/// The paths the `v8` crate's build script needs, handed to the `origine_rs` package as options.
/// Null for a prebuilt V8, which has no GN output to run bindgen against.
pub const RustPaths = struct {
    archive: std.Build.LazyPath,
    mimalloc: std.Build.LazyPath,
    icu: std.Build.LazyPath,
    root: std.Build.LazyPath,
    compile_commands: std.Build.LazyPath,
    binding: std.Build.LazyPath,
};
