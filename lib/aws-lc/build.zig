//! AWS-LC, built by the Zig build system from the vendored aws-lc-sys crate, so that
//! rustls/aws-lc-rs link this copy and aws-lc-sys's build script (cc/cmake) never runs.
//! docs/aws-lc.md has the whole picture.
//!
//! The sources are `rust/vendor/aws-lc-sys`, not an AWS-LC release: it is the exact tree the Rust
//! bindings were generated from and it carries the symbol-prefix headers (`generated-include/`).
//! The hard-coded per-target lists are in `sources.zig`. Everything is compiled with
//! `BORINGSSL_PREFIX=<links>` (`aws_lc_0_47_0`), the prefix the crate's bindings link against.
//!
//! Artifacts: `aws_lc_crypto` (libcrypto, linked by the root) and `aws_lc_ssl` (libssl, C++,
//! `-fno-exceptions -fno-rtti`, QUIC's TLS API; only with `-Dssl`, nothing links it yet). `zig
//! build` installs the tree the vendored aws-lc-sys's build script reads:
//! `<prefix>/{lib,include,links}`. Module `aws_lc`: the C headers for Zig consumers.
//!
//! Options: `-Dtarget`, `-Doptimize`, `-Dsmall` (OPENSSL_SMALL), `-Djitter` (CPU jitter entropy;
//! default on), `-Dssl`.

const std = @import("std");
const sources = @import("sources.zig");

/// The vendored crate, relative to this package (`lib/aws-lc`).
const crate = "../../rust/vendor/aws-lc-sys";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const t = target.result;
    const small = b.option(bool, "small", "OPENSSL_SMALL: smaller and slower code (default false)") orelse false;
    const jitter = b.option(bool, "jitter", "Build the CPU jitter entropy source (default: on)") orelse true;
    const with_ssl = b.option(bool, "ssl", "Build libssl for QUIC's TLS API (default false)") orelse false;

    const links = links_name(b);
    const target_sources = source_list(t);

    const root = b.path(crate ++ "/aws-lc");
    const include_paths: []const std.Build.LazyPath = &.{
        b.path(crate ++ "/aws-lc/include"),
        b.path(crate ++ "/generated-include"),
    };

    const crypto = b.addLibrary(.{
        .name = "aws_lc_crypto",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .pic = true }),
        .linkage = .static,
        .use_llvm = true,
    });
    crypto.link_function_sections = true;
    crypto.link_data_sections = true;
    crypto.link_gc_sections = true;
    configure(crypto.root_module, b, t, links, small, jitter);

    const c_flags: []const []const u8 = if (t.os.tag == .windows) &.{ "-std=c11", "-Wno-unused-parameter" } else &.{ "-std=c11", "-Wno-unused-parameter", "-pthread" };
    crypto.root_module.addCSourceFiles(.{ .root = root, .files = &sources.universal, .flags = c_flags });
    // A non-executable stack for the assembly objects (aws-lc's crypto/CMakeLists.txt does the same on ELF).
    const asm_flags: []const []const u8 = if (t.os.tag == .linux) &.{"-Wa,--noexecstack"} else &.{};
    crypto.root_module.addCSourceFiles(.{ .root = root, .files = target_sources.assembly, .flags = asm_flags });
    // s2n-bignum's assembly is prefixed by a forced include (it does not include `asm_base.h`).
    const s2n_flags: []const []const u8 = &.{ "-include", crate_file(b, "generated-include/openssl/boringssl_prefix_symbols_asm.h"), "-DS2N_BN_HIDE_SYMBOLS=1", "-Wa,--noexecstack" };
    crypto.root_module.addCSourceFiles(.{ .root = root, .files = target_sources.s2n, .flags = s2n_flags[0 .. s2n_flags.len - @intFromBool(t.os.tag != .linux)] });
    // Jitter entropy must not be optimized (aws-lc's third_party/jitterentropy/CMakeLists.txt); the
    // later -O0 wins over the module's level.
    if (jitter) crypto.root_module.addCSourceFiles(.{
        .root = root,
        .files = &sources.jitter_sources,
        .flags = b.graph.dupeStrings(&.{ "-std=c11", "-DAWSLC=1", "-fwrapv", "-fvisibility=hidden", "-O0", "-U_FORTIFY_SOURCE", "-include", crate_file(b, "generated-include/openssl/boringssl_prefix_symbols.h") }),
    });

    const ssl = b.addLibrary(.{
        .name = "aws_lc_ssl",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .link_libcpp = true, .pic = true }),
        .linkage = .static,
        .use_llvm = true,
    });
    ssl.link_function_sections = true;
    ssl.link_data_sections = true;
    ssl.link_gc_sections = true;
    configure(ssl.root_module, b, t, links, small, jitter);
    ssl.root_module.addCSourceFiles(.{ .root = b.path(crate ++ "/aws-lc/ssl"), .files = &sources.ssl_cc, .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti", "-Wno-unused-parameter" } });
    ssl.root_module.addCSourceFiles(.{ .root = b.path(crate ++ "/aws-lc/ssl"), .files = &sources.ssl_c, .flags = c_flags });

    // Installing the artifact also installs the headers attached to it; the whole tree is what the
    // vendored aws-lc-sys's build script reads through `ORIGINE_AWS_LC_PREFIX`.
    for (include_paths) |include_path| crypto.installHeadersDirectory(include_path, "", .{});
    const links_file = b.addWriteFiles().add("links", links);

    // The cargo-facing tree as a generated `LazyPath` (`<dir>/{lib,include,links}`): a consumer
    // passes it to the Rust build without knowing about install steps, and the build dependency
    // comes with the path. `zig build`/`zig build aws-lc-prefix` still install the same layout.
    const include_tree = b.addWriteFiles();
    for (include_paths) |include_path| _ = include_tree.addCopyDirectory(include_path, "", .{});
    const prefix = b.addWriteFiles();
    _ = prefix.addCopyFile(crypto.getEmittedBin(), "lib/libaws_lc_crypto.a");
    _ = prefix.addCopyDirectory(include_tree.getDirectory(), "include", .{});
    _ = prefix.addCopyFile(links_file, "links");
    b.addNamedLazyPath("prefix", prefix.getDirectory());

    b.installArtifact(crypto);
    b.getInstallStep().dependOn(&b.addInstallFile(links_file, "links").step);
    if (with_ssl) b.installArtifact(ssl);

    // For Zig consumers: the public headers with the symbol prefix defined. Linking libcrypto is
    // the artifacts' job (the root adds `aws_lc_crypto` to its native libraries).
    const module = b.addModule("aws_lc", .{ .root_source_file = b.path("aws_lc.zig"), .link_libc = true });
    module.addCMacro("BORINGSSL_PREFIX", links);
    for (include_paths) |include_path| module.addIncludePath(include_path);
}

/// Defines and include paths shared by libcrypto and libssl, as aws-lc-sys's cc builder sets them
/// (builder/cc_builder.rs: `collect_universal_build_options`, `add_includes`, `add_defines`,
/// `run_compiler_checks`; the checks always pass with Zig's clang and libc headers).
fn configure(module: *std.Build.Module, b: *std.Build, t: std.Target, links: []const u8, small: bool, jitter: bool) void {
    module.addCMacro("BORINGSSL_IMPLEMENTATION", "1");
    module.addCMacro("BORINGSSL_PREFIX", links);
    module.addIncludePath(b.path(crate ++ "/generated-include"));
    module.addIncludePath(b.path(crate ++ "/include"));
    module.addIncludePath(b.path(crate ++ "/aws-lc/include"));
    module.addIncludePath(b.path(crate ++ "/aws-lc/third_party/s2n-bignum/include"));
    module.addIncludePath(b.path(crate ++ "/aws-lc/third_party/s2n-bignum/s2n-bignum-imported/include"));
    if (jitter) {
        module.addIncludePath(b.path(crate ++ "/aws-lc/third_party/jitterentropy/jitterentropy-library"));
        module.addIncludePath(b.path(crate ++ "/aws-lc/third_party/jitterentropy/jitterentropy-library/src"));
    } else {
        module.addCMacro("DISABLE_CPU_JITTER_ENTROPY", "1");
    }
    if (small) module.addCMacro("OPENSSL_SMALL", "1");
    module.addCMacro("AWS_LC_STDALIGN_AVAILABLE", "1");
    module.addCMacro("AWS_LC_BUILTIN_SWAP_SUPPORTED", "1");
    if (t.cpu.arch == .aarch64) module.addCMacro("MY_ASSEMBLER_SUPPORTS_NEON_SHA3_EXTENSION", "1");
    switch (t.os.tag) {
        .linux => {
            module.addCMacro("_XOPEN_SOURCE", "700");
            module.addCMacro("HAVE_LINUX_RANDOM_H", "1");
        },
        .macos, .ios, .tvos, .watchos, .visionos => module.addCMacro("_DARWIN_C_SOURCE", "1"),
        .windows => {
            module.addCMacro("WIN32_LEAN_AND_MEAN", "");
            module.addCMacro("NOMINMAX", "");
        },
        else => module.addCMacro("__EXTENSIONS__", "1"),
    }
}

/// The crate's `links` key (`aws_lc_0_47_0`): the symbol prefix of its bindings and the key of the
/// `DEP_AWS_LC_*` metadata the vendored aws-lc-sys emits.
fn links_name(b: *std.Build) []const u8 {
    const manifest = crate_read(b, "Cargo.toml");
    var lines = std.mem.splitScalar(u8, manifest, '\n');
    while (lines.next()) |line| {
        const rest = std.mem.trim(u8, line, " \r");
        if (!std.mem.startsWith(u8, rest, "links = \"")) continue;
        return std.mem.trimEnd(u8, rest["links = \"".len..], "\"");
    }
    std.debug.panic("aws-lc-sys Cargo.toml has no `links` key", .{});
}

/// The assembly lists for `t`: `sources.universal` is shared, these are added on top. Only
/// origine's targets are accepted: aarch64 macOS and x86_64/aarch64 Linux, all with assembly.
fn source_list(t: std.Target) struct { assembly: []const []const u8, s2n: []const []const u8 } {
    return switch (t.os.tag) {
        .macos => switch (t.cpu.arch) {
            .aarch64 => .{ .assembly = &sources.apple_aarch64_asm, .s2n = &sources.apple_aarch64_s2n },
            else => std.debug.panic("aws-lc: unsupported target {s}-macos (only aarch64-macos)", .{@tagName(t.cpu.arch)}),
        },
        .linux => switch (t.cpu.arch) {
            .aarch64 => .{ .assembly = &sources.linux_aarch64_asm, .s2n = &sources.linux_aarch64_s2n },
            .x86_64 => .{ .assembly = &sources.linux_x86_64_asm, .s2n = &sources.linux_x86_64_s2n },
            else => std.debug.panic("aws-lc: unsupported target {s}-linux (only x86_64, aarch64)", .{@tagName(t.cpu.arch)}),
        },
        else => std.debug.panic("aws-lc: unsupported OS {s} (aarch64-macos, x86_64/aarch64-linux)", .{@tagName(t.os.tag)}),
    };
}

/// A file's path as a string for a compiler flag (`-include` takes no LazyPath): relative to the
/// package root, which is also where the compiler runs.
fn crate_file(b: *std.Build, sub_path: []const u8) []const u8 {
    return b.root.joinString(b.allocator, b.fmt("{s}/{s}", .{ crate, sub_path })) catch @panic("OOM");
}

/// Reads a file at configure time.
fn crate_read(b: *std.Build, sub_path: []const u8) []const u8 {
    const path = b.root.join(b.allocator, b.fmt("{s}/{s}", .{ crate, sub_path })) catch @panic("OOM");
    return path.root_dir.handle.readFileAlloc(b.graph.io, path.sub_path, b.allocator, .limited(16 << 20)) catch |err|
        std.debug.panic("reading {f}: {t}", .{ path, err });
}
