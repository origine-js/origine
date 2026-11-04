//! The Rust workspace as a Zig package (`origine_rs`): cargo owns the build, this file owns the
//! invocation and the pre-link step, and the root owns the final link. Everything that comes from
//! the root's native dependencies (V8, AWS-LC) arrives as a `LazyPath` option, so this package has
//! no edge back into the root's build graph. See rust/docs/README.md and docs/aws-lc.md.

const std = @import("std");

/// The paths the vendored `v8` crate's build script needs (lib/v8_zig). Null for a prebuilt V8,
/// where cargo runs bare and the crate's build script reports the missing variables.
const V8 = struct {
    archive: std.Build.LazyPath,
    mimalloc: std.Build.LazyPath,
    icu: std.Build.LazyPath,
    root: std.Build.LazyPath,
    compile_commands: std.Build.LazyPath,
    binding: std.Build.LazyPath,
};

/// CONTRACT (docs/contracts.md, surface F): the symbol prefixes the pre-linked Rust object keeps
/// global (Zig, the V8 bindings and the C++ glue call into them). The macOS export list and the
/// Linux objcopy patterns are both generated from this one list. Every `#[no_mangle]` item of the
/// Rust crates must start with one of these (`just check-contracts` greps for violations); the
/// first prefix is origine's own C ABI (`origine_oxc_*`, `origine_api_*`, `origine_api_native_*`).
const kept_symbol_prefixes = [_][]const u8{ "origine_", "crdtp__", "v8_inspector__", "rusty_v8_RustObj_", "v8__ValueSerializer__Delegate__", "v8__ValueDeserializer__Delegate__" };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const offline = b.option(bool, "cargo_offline", "Run cargo with --offline") orelse false;
    const features = b.option([]const u8, "features", "Comma-separated cargo features") orelse "";
    const v8: ?V8 = if (b.option(std.Build.LazyPath, "v8_archive", "libv8_zig.a")) |archive| .{
        .archive = archive,
        .mimalloc = optionPath(b, "v8_mimalloc", "mimalloc archive"),
        .icu = optionPath(b, "v8_icu", "ICU data archive"),
        .root = optionPath(b, "v8_root", "V8 checkout"),
        .compile_commands = optionPath(b, "v8_compile_commands", "GN compile_commands.json"),
        .binding = optionPath(b, "v8_binding", "rusty_v8 binding sources"),
    } else null;
    const aws_lc = b.option(std.Build.LazyPath, "aws_lc_prefix", "AWS-LC tree (lib/, include/, links)");
    const aws_lc_host = b.option(std.Build.LazyPath, "aws_lc_host_prefix", "Host AWS-LC tree for clippy");

    const result = target.result;
    const triple = rustTriple(b, result);
    const file_name = if (result.os.tag == .windows and result.abi == .msvc) "origine_native.lib" else "liborigine_native.a";

    // One cargo run: the archive the root links and the object the pre-link step derives from it.
    // It is cached on the declared sources and Cargo.lock; `cargo` itself decides what to relink.
    // The archive is an output of this Run (cargo-env.py copies it out of `target/`), not a
    // `WriteFile` copy: a cache hit must deliver the file from the cache, and a copy step that
    // reruns would rewrite its inode and invalidate every program that links the archive.
    var archive: std.Build.LazyPath = undefined;
    const cargo = cargoCommand(b, v8, aws_lc, offline, .{
        .artifact = b.fmt("target/{s}/release/{s}", .{ triple, file_name }),
        .basename = file_name,
        .output = &archive,
    }, &.{ "build", "--release", "--locked", "--target", triple });
    cargo.addArgs(&.{ "--no-default-features", "--features", features });
    cargo.addArg("--target-dir");
    cargo.addDirectoryArg2(b.path("target"), .{ .make_absolute = true });
    for (cargoInputs(b)) |path| cargo.addFileInput(b.path(path));
    b.step("build", "Build liborigine_native.a and the pre-linked object").dependOn(&cargo.step);
    b.addNamedLazyPath("archive", archive);
    b.addNamedLazyPath("object", prelinked(b, result, archive));

    b.step("clippy", "Run clippy (-D warnings) over the Rust workspace").dependOn(&cargoCommand(b, v8, aws_lc_host orelse aws_lc, offline, null, &.{ "clippy", "--locked", "--workspace", "--all-targets", "--", "-D", "warnings" }).step);
    b.step("test-alloc", "Test the Rust mimalloc bindings against the Zig-built mimalloc").dependOn(&cargoCommand(b, v8, null, offline, null, &.{ "test", "--locked", "-p", "origine_alloc" }).step);
}

/// A required `LazyPath` option: the root always passes the full V8 set or none of it.
fn optionPath(b: *std.Build, name: []const u8, description: []const u8) std.Build.LazyPath {
    return b.option(std.Build.LazyPath, name, description) orelse
        std.debug.panic("-Dv8_archive also needs -D{s}", .{name});
}

/// A cargo invocation for this package, through `scripts/cargo-env.py`, which exports the paths the
/// build scripts of the vendored crates read: V8_ZIG_* (`v8`) and ORIGINE_AWS_LC_PREFIX (`aws_lc`).
/// A file cargo writes under rust/ (`artifact`) that becomes an output of the Run, named
/// `basename`; `output` receives its `LazyPath`.
const CargoOutput = struct { artifact: []const u8, basename: []const u8, output: *std.Build.LazyPath };

fn cargoCommand(b: *std.Build, v8: ?V8, aws_lc: ?std.Build.LazyPath, offline: bool, copy: ?CargoOutput, args: []const []const u8) *std.Build.Step.Run {
    const run = std.Build.Step.Run.create(b, b.fmt("cargo {s}", .{args[0]}));
    // `--no-cache`: the script has no dependencies and a build must not need a writable uv cache.
    run.addArgs(&.{ "uv", "run", "--quiet", "--no-cache", "--script" });
    run.addFileArg2(b.path("scripts/cargo-env.py"), .{ .make_absolute = true });
    if (v8) |paths| {
        run.addFileArg2(paths.archive, .{ .prefix = "V8_ZIG_ARCHIVE=" });
        run.addFileArg2(paths.mimalloc, .{ .prefix = "V8_ZIG_MIMALLOC=" });
        run.addFileArg2(paths.icu, .{ .prefix = "V8_ZIG_ICU=" });
        // Directory arguments are cached by path, not contents. The V8 checkout and its GN output
        // change with the archive (a file input above); the binding directory is source, so the
        // headers the `v8` build script reads from it are inputs of their own.
        run.addDirectoryArg2(paths.root, .{ .prefix = "V8_ZIG_V8_ROOT=" });
        run.addDirectoryArg2(paths.compile_commands.dirname(), .{ .prefix = "V8_ZIG_GN_OUT=" });
        run.addDirectoryArg2(paths.binding, .{ .prefix = "V8_ZIG_BINDING=" });
        for ([_][]const u8{ "binding.hpp", "support.h" }) |header| run.addFileInput(paths.binding.path(b, header));
    }
    // A generated tree (WriteFile directory): its path changes with its contents.
    if (aws_lc) |prefix| run.addDirectoryArg2(prefix, .{ .prefix = "ORIGINE_AWS_LC_PREFIX=" });
    if (copy) |c| {
        run.addArgs(&.{ "--copy", c.artifact });
        c.output.* = run.addOutputFileArg2(c.basename, .{});
    }
    run.addArgs(&.{ "--", "cargo", args[0] });
    if (offline) run.addArg("--offline");
    run.addArg("--manifest-path");
    run.addFileArg2(b.path("Cargo.toml"), .{ .make_absolute = true });
    run.addArgs(args[1..]);
    return run;
}

/// Every file cargo reads that is not already a `LazyPath` input (V8, AWS-LC, the toolchain):
/// the workspace manifests and lockfile, and each crate's sources and build script. Zig caches
/// a `Run` on its declared inputs, so these are what decide whether cargo runs at all; cargo
/// still owns incremental compilation and relinking inside the run. `target/` is not an input
/// (it is the build output) and neither is `.git`. Returns paths relative to the package root
/// and borrows b through build teardown.
fn cargoInputs(b: *std.Build) []const []const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "Cargo.toml", "Cargo.lock" }) |path| paths.append(b.allocator, path) catch @panic("OOM");
    // This package's directory (rust/), not the process cwd, which is the root package's.
    var dir = b.root.openDir(b.graph.io, ".", .{ .iterate = true }) catch @panic("cannot open rust/");
    defer dir.close(b.graph.io);
    var walker = dir.walk(b.allocator) catch @panic("OOM");
    defer walker.deinit();
    while (walker.next(b.graph.io) catch @panic("cannot walk rust/")) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.path;
        // Rooted at `src/`, `crates/` and `scripts/`, or a top-level `*.toml`/`*.rs`.
        const is_source = std.mem.startsWith(u8, name, "src/") or
            std.mem.startsWith(u8, name, "crates/") or
            std.mem.startsWith(u8, name, "scripts/") or
            std.mem.indexOfScalar(u8, name, '/') == null;
        if (!is_source) continue;
        if (!(std.mem.endsWith(u8, name, ".toml") or
            std.mem.endsWith(u8, name, ".rs") or
            std.mem.endsWith(u8, name, ".py") or
            std.mem.endsWith(u8, name, ".h"))) continue;
        paths.append(b.allocator, b.dupe(name)) catch @panic("OOM");
    }
    return paths.items;
}

/// The pre-linked object the root's external link uses (or the archive where the platform has no
/// pre-link step). The archive carries its own copy of Rust's std, which defines symbols
/// (rust_eh_personality, ...) that V8's bundled Rust code defines too; pre-linking it into one
/// object that exports only the `origine_*` C API makes everything else local, so the final link
/// sees no duplicates. Windows links the archive as it is.
fn prelinked(b: *std.Build, result: std.Target, archive: std.Build.LazyPath) std.Build.LazyPath {
    switch (result.os.tag) {
        .macos => {
            const partial = b.addSystemCommand(&.{ "/usr/bin/clang", "-arch", if (result.cpu.arch == .aarch64) "arm64" else "x86_64", "-r", "-nostdlib" });
            var list: std.ArrayList(u8) = .empty;
            for (kept_symbol_prefixes) |prefix| list.print(b.allocator, "_{s}*\n", .{prefix}) catch @panic("OOM");
            const exports = b.addWriteFiles().add("exports.macos.txt", list.items);
            partial.addFileArg2(exports, .{ .prefix = "-Wl,-exported_symbols_list," });
            partial.addArg("-Wl,-all_load");
            partial.addFileArg2(archive, .{});
            partial.addArg("-o");
            return partial.addOutputFileArg2("origine_native.o", .{});
        },
        .linux => {
            const merge = b.addSystemCommand(&.{ "ld", "-r", "--whole-archive" });
            merge.addFileArg2(archive, .{});
            merge.addArg("-o");
            const merged = merge.addOutputFileArg2("origine_native_all.o", .{});
            const localize = b.addSystemCommand(&.{ "objcopy", "--wildcard" });
            for (kept_symbol_prefixes) |prefix| localize.addArg(b.fmt("--keep-global-symbol={s}*", .{prefix}));
            localize.addFileArg2(merged, .{});
            return localize.addOutputFileArg2("origine_native.o", .{});
        },
        else => return archive,
    }
}

/// The Rust target triple for a Zig target. Unsupported targets are a build error.
fn rustTriple(b: *std.Build, result: std.Target) []const u8 {
    const arch = switch (result.cpu.arch) {
        .aarch64 => "aarch64",
        .x86_64 => "x86_64",
        else => std.debug.panic("No Rust target for {s}", .{@tagName(result.cpu.arch)}),
    };
    return switch (result.os.tag) {
        .macos => b.fmt("{s}-apple-darwin", .{arch}),
        .linux => b.fmt("{s}-unknown-linux-{s}", .{ arch, if (result.abi.isMusl()) "musl" else "gnu" }),
        .windows => b.fmt("{s}-pc-windows-{s}", .{ arch, if (result.abi == .msvc) "msvc" else "gnu" }),
        else => std.debug.panic("No Rust target for {s}", .{@tagName(result.os.tag)}),
    };
}
