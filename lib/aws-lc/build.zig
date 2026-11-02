//! AWS-LC, built by the Zig build system from the sources of the pinned aws-lc-sys crate, so that
//! rustls/aws-lc-rs link this copy and aws-lc-sys's build script (cc/cmake) never runs.
//! docs/aws-lc.md has the whole picture.
//!
//! The package is the aws-lc-sys `.crate` itself (build.zig.zon), not an AWS-LC release: it is the
//! exact source the Rust bindings were generated from, it carries the symbol-prefix headers
//! (`generated-include/`) and it lists the sources per target (`builder/cc_builder/*.rs`), which
//! this file reads at configure time. Everything is compiled with `BORINGSSL_PREFIX=<links>`
//! (`aws_lc_0_47_0`), the prefix the crate's bindings link against.
//!
//! Artifacts:
//! * `aws_lc_crypto`: libcrypto, what aws-lc-rs needs. Assembly on aarch64/x86_64 macOS and
//!   Linux (and the other Linux arches aws-lc-sys has lists for); C only on Windows (its x86_64
//!   assembly is NASM) and unknown arches.
//! * `aws_lc_ssl`: libssl (C++, `-fno-exceptions -fno-rtti`), for QUIC's TLS API
//!   (`SSL_set_quic_method`). Built on request only; it needs a C++ runtime from the consumer.
//!   Its own `SSL_*` names are not prefixed (the prefix list covers libcrypto only); its calls into
//!   libcrypto are.
//!
//! Named lazy paths: `prefix`, a tree (`lib/libaws_lc_crypto.a`, `include/`, `links`) for
//! `rust/scripts/cargo-aws-lc.sh`; `include`, the headers. C consumers of the headers must
//! define `BORINGSSL_PREFIX` to the contents of `links`.
//!
//! Options: `-Dtarget`, `-Doptimize`, `-Dsmall` (OPENSSL_SMALL: smaller tables, slower; default
//! off), `-Djitter` (CPU jitter entropy as an extra seed source; default on except for Apple
//! targets cross-compiled without an SDK, where `CoreServices.h` is missing).
//! `zig build` installs the `prefix` layout plus `lib/libaws_lc_ssl.a`.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const small = b.option(bool, "small", "OPENSSL_SMALL: smaller and slower code (default false)") orelse false;
    const t = target.result;
    const jitter = b.option(bool, "jitter", "Build the CPU jitter entropy source (default: on unless Apple without SDK)") orelse
        !(t.os.tag.isDarwin() and !target.query.isNative());

    const source: Crate = .{ .b = b, .dep = b.dependency("source", .{}) };
    const arena = b.allocator;
    const links = linksName(source);
    const sources = sourceList(b, source, t);

    const crypto_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .pic = true });
    configure(crypto_module, source, t, links, small, jitter, sources.asm_ok);
    var c_files: std.ArrayList([]const u8) = .empty;
    var asm_files: std.ArrayList([]const u8) = .empty;
    var s2n_files: std.ArrayList([]const u8) = .empty;
    var jitter_files: std.ArrayList([]const u8) = .empty;
    for (sources.files) |file| {
        const list = if (std.mem.startsWith(u8, file, "third_party/s2n-bignum/"))
            &s2n_files
        else if (std.mem.startsWith(u8, file, "third_party/jitterentropy/"))
            (if (jitter) &jitter_files else continue)
        else if (std.mem.endsWith(u8, file, ".S"))
            &asm_files
        else if (std.mem.endsWith(u8, file, ".c"))
            &c_files
        else
            // `.asm` (NASM) is listed for Windows only, where `sourceList` selects no assembly.
            std.debug.panic("aws-lc: unexpected source {s}", .{file});
        list.append(arena, file) catch @panic("OOM");
    }
    const root = source.path("aws-lc");
    const c_flags: []const []const u8 = if (t.os.tag == .windows) &.{ "-std=c11", "-Wno-unused-parameter" } else &.{ "-std=c11", "-Wno-unused-parameter", "-pthread" };
    crypto_module.addCSourceFiles(.{ .root = root, .files = c_files.items, .flags = c_flags });
    // A non-executable stack for the assembly objects (aws-lc's crypto/CMakeLists.txt does the same on ELF).
    const asm_flags: []const []const u8 = if (t.os.tag == .linux) &.{"-Wa,--noexecstack"} else &.{};
    crypto_module.addCSourceFiles(.{ .root = root, .files = asm_files.items, .flags = asm_flags });
    // s2n-bignum's assembly is prefixed by a forced include (it does not include `asm_base.h`).
    const s2n_flags: []const []const u8 = &.{ "-include", source.file("generated-include/openssl/boringssl_prefix_symbols_asm.h"), "-DS2N_BN_HIDE_SYMBOLS=1", "-Wa,--noexecstack" };
    crypto_module.addCSourceFiles(.{ .root = root, .files = s2n_files.items, .flags = s2n_flags[0 .. s2n_flags.len - @intFromBool(t.os.tag != .linux)] });
    // Jitter entropy must not be optimized (aws-lc's third_party/jitterentropy/CMakeLists.txt); the
    // later -O0 wins over the module's level.
    crypto_module.addCSourceFiles(.{ .root = root, .files = jitter_files.items, .flags = b.dupeStrings(&.{ "-std=c11", "-DAWSLC=1", "-fwrapv", "-fvisibility=hidden", "-O0", "-U_FORTIFY_SOURCE", "-include", source.file("generated-include/openssl/boringssl_prefix_symbols.h") }) });
    const crypto = b.addLibrary(.{ .name = "aws_lc_crypto", .linkage = .static, .root_module = crypto_module, .use_llvm = true });

    const ssl_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .link_libcpp = true, .pic = true });
    configure(ssl_module, source, t, links, small, jitter, sources.asm_ok);
    const ssl_files = sslSources(b, source);
    ssl_module.addCSourceFiles(.{ .root = source.path("aws-lc/ssl"), .files = ssl_files.cc, .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti", "-Wno-unused-parameter" } });
    ssl_module.addCSourceFiles(.{ .root = source.path("aws-lc/ssl"), .files = ssl_files.c, .flags = c_flags });
    const ssl = b.addLibrary(.{ .name = "aws_lc_ssl", .linkage = .static, .root_module = ssl_module, .use_llvm = true });

    const include = b.addWriteFiles();
    _ = include.addCopyDirectory(source.path("aws-lc/include"), "", .{});
    _ = include.addCopyDirectory(source.path("generated-include"), "", .{});
    b.addNamedLazyPath("include", include.getDirectory());
    const links_file = b.addWriteFiles().add("links", links);

    // The tree rust/scripts/cargo-aws-lc.sh takes, for a consumer's cargo invocation.
    const tree = b.addWriteFiles();
    _ = tree.addCopyFile(crypto.getEmittedBin(), "lib/libaws_lc_crypto.a");
    _ = tree.addCopyDirectory(include.getDirectory(), "include", .{});
    _ = tree.addCopyFile(links_file, "links");
    b.addNamedLazyPath("prefix", tree.getDirectory());

    // `zig build crypto` installs the same layout under the prefix (for `just test-net`); `zig build`
    // adds libssl.
    // (Artifacts hang off the install step directly: that is where `Dependency.artifact` looks.)
    const install_crypto = b.addInstallArtifact(crypto, .{});
    b.getInstallStep().dependOn(&install_crypto.step);
    b.installArtifact(ssl);
    const crypto_step = b.step("crypto", "Install libcrypto, the headers and `links` (no libssl)");
    crypto_step.dependOn(&install_crypto.step);
    crypto_step.dependOn(&b.addInstallDirectory(.{ .source_dir = include.getDirectory(), .install_dir = .header, .install_subdir = "" }).step);
    crypto_step.dependOn(&b.addInstallFile(links_file, "links").step);
    b.getInstallStep().dependOn(crypto_step);
}

/// Defines and include paths shared by libcrypto and libssl, as aws-lc-sys's cc builder sets them
/// (builder/cc_builder.rs: `collect_universal_build_options`, `add_includes`, `add_defines`,
/// `run_compiler_checks`; the checks always pass with Zig's clang and libc headers).
fn configure(module: *std.Build.Module, source: Crate, t: std.Target, links: []const u8, small: bool, jitter: bool, asm_ok: bool) void {
    module.addCMacro("BORINGSSL_IMPLEMENTATION", "1");
    module.addCMacro("BORINGSSL_PREFIX", links);
    module.addIncludePath(source.path("generated-include"));
    module.addIncludePath(source.path("include"));
    module.addIncludePath(source.path("aws-lc/include"));
    module.addIncludePath(source.path("aws-lc/third_party/s2n-bignum/include"));
    module.addIncludePath(source.path("aws-lc/third_party/s2n-bignum/s2n-bignum-imported/include"));
    if (jitter) {
        module.addIncludePath(source.path("aws-lc/third_party/jitterentropy/jitterentropy-library"));
        module.addIncludePath(source.path("aws-lc/third_party/jitterentropy/jitterentropy-library/src"));
    } else {
        module.addCMacro("DISABLE_CPU_JITTER_ENTROPY", "1");
    }
    if (!asm_ok) module.addCMacro("OPENSSL_NO_ASM", "1");
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

/// The crate's `links` key (`aws_lc_0_47_0`): the symbol prefix of its bindings and the key of
/// the cargo build-script override (rust/scripts/cargo-aws-lc.sh).
fn linksName(source: Crate) []const u8 {
    const manifest = source.read("Cargo.toml");
    var lines = std.mem.splitScalar(u8, manifest, '\n');
    while (lines.next()) |line| {
        const rest = std.mem.trim(u8, line, " \r");
        if (!std.mem.startsWith(u8, rest, "links = \"")) continue;
        return std.mem.trimEnd(u8, rest["links = \"".len..], "\"");
    }
    std.debug.panic("aws-lc-sys Cargo.toml has no `links` key", .{});
}

const Sources = struct { files: []const []const u8, asm_ok: bool };

/// The quoted paths of `builder/cc_builder/universal.rs` plus the list for the target (the same
/// choice as `identify_sources` there). No list (Windows, other arches): C only, OPENSSL_NO_ASM.
fn sourceList(b: *std.Build, source: Crate, t: std.Target) Sources {
    const arch: ?[]const u8 = switch (t.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .arm => "arm",
        .x86 => "x86",
        .powerpc64le => "ppc64le",
        else => null,
    };
    const platform: ?[]const u8 = if (t.os.tag == .windows) null else if (t.os.tag.isDarwin()) switch (t.cpu.arch) {
        .x86_64, .aarch64 => b.fmt("apple_{s}", .{arch.?}),
        else => null,
    } else if (arch) |a| b.fmt("linux_{s}", .{a}) else null;
    var files: std.ArrayList([]const u8) = .empty;
    quotedLines(b, source.read("builder/cc_builder/universal.rs"), &files);
    if (platform) |name| quotedLines(b, source.read(b.fmt("builder/cc_builder/{s}.rs", .{name})), &files);
    return .{ .files = files.items, .asm_ok = platform != null };
}

/// libssl's sources: the `.cc`/`.c` names of the `add_library(ssl ...)` call in aws-lc/ssl/CMakeLists.txt.
fn sslSources(b: *std.Build, source: Crate) struct { cc: []const []const u8, c: []const []const u8 } {
    const cmake = source.read("aws-lc/ssl/CMakeLists.txt");
    const start = std.mem.indexOf(u8, cmake, "add_library(\n  ssl\n") orelse std.debug.panic("aws-lc/ssl/CMakeLists.txt: no add_library(ssl)", .{});
    const end = std.mem.indexOfScalarPos(u8, cmake, start, ')') orelse unreachable;
    var cc: std.ArrayList([]const u8) = .empty;
    var c: std.ArrayList([]const u8) = .empty;
    var words = std.mem.tokenizeAny(u8, cmake[start..end], " \n\r\t");
    while (words.next()) |word| {
        const list = if (std.mem.endsWith(u8, word, ".cc")) &cc else if (std.mem.endsWith(u8, word, ".c")) &c else continue;
        list.append(b.allocator, word) catch @panic("OOM");
    }
    return .{ .cc = cc.items, .c = c.items };
}

/// Appends every `"path",` line of a cc_builder list.
fn quotedLines(b: *std.Build, text: []const u8, files: *std.ArrayList([]const u8)) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r");
        if (trimmed.len < 3 or trimmed[0] != '"' or !std.mem.endsWith(u8, trimmed, "\",")) continue;
        files.append(b.allocator, trimmed[1 .. trimmed.len - 2]) catch @panic("OOM");
    }
}

/// The fetched `.crate`: Zig keeps its top-level `aws-lc-sys-<version>/` directory, so every path
/// goes through here. The version is this package's (build.zig.zon), kept equal to the crate's.
const Crate = struct {
    b: *std.Build,
    dep: *std.Build.Dependency,

    const dir = "aws-lc-sys-" ++ @import("build.zig.zon").version ++ "/";

    fn path(c: Crate, sub_path: []const u8) std.Build.LazyPath {
        return c.dep.path(c.b.fmt(dir ++ "{s}", .{sub_path}));
    }

    /// A file's path as a string for a compiler flag (`-include` takes no LazyPath): the package
    /// root as the build runner sees it, which is also where the compiler runs.
    fn file(c: Crate, sub_path: []const u8) []const u8 {
        const p = c.dep.builder.root.join(c.b.allocator, c.b.fmt(dir ++ "{s}", .{sub_path})) catch @panic("OOM");
        return p.toString(c.b.allocator) catch @panic("OOM");
    }

    /// Reads a file at configure time (the source lists decide what to compile).
    fn read(c: Crate, sub_path: []const u8) []const u8 {
        const p = c.dep.builder.root.join(c.b.allocator, c.b.fmt(dir ++ "{s}", .{sub_path})) catch @panic("OOM");
        return p.root_dir.handle.readFileAlloc(c.b.graph.io, p.sub_path, c.b.allocator, .limited(16 << 20)) catch |err|
            std.debug.panic("reading {f}: {t}", .{ p, err });
    }
};
