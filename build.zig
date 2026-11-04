const std = @import("std");
const v8_build = @import("build/v8.zig");
const rust_build = @import("build/rust.zig");

/// Borrows b and its configuration through build teardown; creates build-owned
/// dependency modules, cached artifacts and install/run/test steps. Retains no runtime state.
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const external_link = target.result.os.tag == .macos and optimize != .debug;
    // AWS-LC options (docs/aws-lc.md); read here because the build creates it for two targets.
    const aws_lc_small = b.option(bool, "aws_lc_small", "AWS-LC OPENSSL_SMALL: smaller and slower code (default: off)") orelse false;
    const aws_lc_jitter = b.option(bool, "aws_lc_jitter", "Build AWS-LC's CPU jitter entropy source (default: on)");
    // Release V8 by default; a debug V8 compiles faster and is for working on V8 patches.
    const v8_debug = b.option(bool, "v8_debug", "Build V8 in debug mode for quick iteration on V8 patches (default: release V8)") orelse false;
    // The V8 sandbox confines JS memory (ArrayBuffers use a mimalloc arena inside it). Off
    // only for Zig-allocated backing stores or tools that need memory outside the sandbox.
    const v8_sandbox = b.option(bool, "v8_sandbox", "Build V8 with the sandbox (default: on; off also disables builtin PGO)") orelse true;
    // The memory corruption API (V8_ENABLE_MEMORY_CORRUPTION_API) is for sandbox testing: V8 exposes it only
    // under --sandbox-testing or --sandbox-fuzzing. Needs the sandbox; the V8 package rejects the other combination.
    const v8_memory_corruption_api = b.option(bool, "v8_memory_corruption_api", "Build V8 with the memory corruption API (default: off; requires the sandbox)") orelse false;
    const v8_builtin_pgo = b.option(bool, "v8_builtin_pgo", "Use Google's exact-version builtin PGO baseline (default: release desktop V8, needs the sandbox)") orelse (!v8_debug and v8_sandbox and target.result.os.tag != .ios);
    // V8 builds from source only on the first build and for `zig build build-v8` (patches apply
    // automatically, ninja makes it incremental); other builds reuse the last archive. An
    // explicit archive skips that.
    const v8_prebuilt: ?[]const u8 = b.option([]const u8, "v8_prebuilt_path", "Path to a prebuilt V8 archive");
    const clang_bin = b.option([]const u8, "v8_clang_dir", "Matching V8 LLVM bin directory") orelse "";
    const v8_cache_root = b.option([]const u8, "v8_cache_root", "V8 checkout and toolchain cache") orelse
        (b.root.joinString(b.allocator, "lib/v8_zig/.lp-cache") catch @panic("OOM"));
    // The Rust staticlib (rust/) is part of the core and always built; `typescript` only selects
    // whether the oxc transformer is compiled into it.
    const typescript = b.option(bool, "typescript", "Include the oxc TypeScript/JSX transformer in the Rust library (default true)") orelse true;
    const rust_offline = b.option(bool, "rust_cargo_offline", "Run cargo with --offline") orelse false;
    // Networking (docs/http-design.md). Each flag removes its API (the name is absent, not stubbed), its
    // Rust feature and its C dependencies; a disabled flag fetches none of them.
    const http = b.option(bool, "http", "HTTP/2 client and server (api.http; links nghttp2) (default true)") orelse true;
    const tls = b.option(bool, "tls", "TLS (api.tls; rustls) (default true)") orelse true;
    const dns = b.option(bool, "dns", "DNS resolver (api.dns) (default true)") orelse true;
    const quic = b.option(bool, "quic", "QUIC and api.net.udp (default true; needs -Dtls)") orelse true;
    if (quic and !tls) std.process.fatal("-Dquic depends on -Dtls", .{});
    const rust_features = b.fmt("{s}{s}{s}{s}{s}", .{
        if (typescript) "typescript," else "",
        if (http) "http," else "",
        if (tls) "tls," else "",
        if (dns) "dns," else "",
        if (quic) "quic," else "",
    });
    // Size over startup, opt in per blob: LZ4 HC (lib/lz4) shrinks the executable or the caches on
    // disk and costs a decode (about 0.1 ms for the 0.5 MB engine snapshot) plus the expanded copy on the heap.
    const v8_icu = b.option(v8_build.IcuMode, "v8_icu", "ICU data in the executable: compressed (zstd, expanded on first Intl use; default) or raw (about 7 MB larger, no expansion)") orelse .compressed;
    const engine_snapshot = b.option(Embedding, "engine_snapshot", "Engine snapshot embedded in the executable: raw (default) or compressed (LZ4 HC, expanded at startup)") orelse .raw;
    const user_snapshot = b.option(Embedding, "user_snapshot", "Init snapshot files in the global cache: raw (default) or compressed (LZ4 HC)") orelse .raw;
    const user_codecache = b.option(Embedding, "user_codecache", "Code cache files in the global cache: raw (default) or compressed (LZ4 HC)") orelse .raw;
    const config = b.addOptions();
    config.addOption(bool, "typescript", typescript);
    config.addOption(bool, "http", http);
    config.addOption(bool, "tls", tls);
    config.addOption(bool, "dns", dns);
    config.addOption(bool, "quic", quic);
    config.addOption(bool, "user_snapshot_compressed", user_snapshot == .compressed);
    config.addOption(bool, "user_codecache_compressed", user_codecache == .compressed);
    const v8_options: v8_build.Options = .{ .target = target, .v8_debug = v8_debug, .v8_sandbox = v8_sandbox, .v8_memory_corruption_api = v8_memory_corruption_api, .builtin_pgo = v8_builtin_pgo, .v8_icu = v8_icu, .prebuilt = v8_prebuilt, .clang_bin = clang_bin, .cache_root = v8_cache_root };
    const v8 = v8_build.dependency(b, v8_options, !external_link);
    // The Rust crates that use the `v8` crate build against this V8 (headers, GN defines, archive path).
    const v8_paths: ?v8_build.RustPaths = if (v8_prebuilt == null) .{
        .archive = v8.namedLazyPath("v8"),
        .mimalloc = v8.artifact("mimalloc").getEmittedBin(),
        .icu = v8.artifact("v8_icu").getEmittedBin(),
        .root = v8.namedLazyPath("v8_root"),
        .compile_commands = v8.namedLazyPath("gn_compile_commands"),
        .binding = v8.namedLazyPath("binding"),
    } else null;
    // rustls/aws-lc-rs link the Zig-built AWS-LC (lib/aws-lc): the vendored aws-lc-sys only emits
    // link directives for it and never compiles AWS-LC itself (docs/aws-lc.md). Null without -Dtls,
    // or while the lazy dependency is being fetched (the build then runs again).
    const aws_lc: ?*std.Build.Dependency = if (tls) try b.dependencyLazy("aws_lc", .{
        .target = target,
        .optimize = .fast,
        .small = aws_lc_small,
        .jitter = aws_lc_jitter,
        .ssl = quic,
    }) else null;
    // `initSnapshot`/`just test-net` point cargo at an installed tree (`zig-out` after
    // `zig build aws-lc-prefix`); `zig build` hands the generated tree to the Rust package instead.
    const aws_lc_prefix = b.step("aws-lc-prefix", "Install the AWS-LC tree the Rust build links against");
    if (aws_lc) |dep| aws_lc_prefix.dependOn(dep.builder.getInstallStep());
    // Clippy checks every crate whatever the features, origine_tls (and so aws-lc-sys) included,
    // for the host: it gets a host AWS-LC so the vendored aws-lc-sys links a real library.
    const host_aws_lc: ?*std.Build.Dependency = if (!tls) null else try b.dependencyLazy("aws_lc", .{
        .target = b.graph.host,
        .optimize = .fast,
        .small = aws_lc_small,
        .jitter = aws_lc_jitter,
        .ssl = false,
    });
    // rust/ is its own package: it owns cargo and the pre-link step; the root owns the final link.
    const rust = try rust_build.dependency(b, .{
        .target = target,
        .features = rust_features,
        .offline = rust_offline,
        .aws_lc_prefix = if (aws_lc) |dep| dep.namedLazyPath("prefix") else null,
        .aws_lc_host_prefix = if (host_aws_lc) |dep| dep.namedLazyPath("prefix") else null,
        .v8 = v8_paths,
    });
    // Zig-linked programs (debug, tests) resolve duplicate Rust runtime symbols on their own and
    // would break on a pre-linked object (thread-locals), so they take the plain archive.
    const rust_archive = rust.namedLazyPath("archive");
    const rust_program = if (external_link) rust.namedLazyPath("object") else rust_archive;
    b.step("test-alloc", "Test the Rust mimalloc bindings against the Zig-built mimalloc").dependOn(rust_build.step(rust, "test-alloc"));
    b.step("clippy", "Run clippy (-D warnings) over the Rust workspace with the V8 environment").dependOn(rust_build.step(rust, "clippy"));
    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = !external_link,
    });
    for ([_][]const u8{ "@v8", "@util", "@diagnostics" }) |name| {
        root.addImport(name, v8.module(name));
    }
    if (aws_lc) |dep| root.addImport("aws_lc", dep.module("aws_lc"));
    // The I/O library: the Zig host uses `Loop` and the Rust runtime calls its `oio_*` C ABI, so
    // every program that links the Rust library must compile it in (see `io_module`).
    const io_module = ioModule(b, target);
    const io_lib = ioLibrary(b, target, io_module);
    const lz4_dep = b.dependency("lz4", .{ .target = target, .optimize = .small });
    const lz4_lib = lz4_dep.artifact("lz4");
    const icu_lib: ?*std.Build.Step.Compile = if (v8_prebuilt == null) v8.artifact("v8_icu") else null;
    // The Rust HTTP/2 crate binds nghttp2's C ABI; like `oio_*`, every program that links the Rust library links it.
    const nghttp2_lib: ?*std.Build.Step.Compile = if (http) try nghttp2Library(b, target) else null;
    // libcrypto for aws-lc-rs: the Rust library refers to it without embedding it (`-bundle`).
    const aws_lc_crypto: ?*std.Build.Step.Compile = if (aws_lc) |dep| dep.artifact("aws_lc_crypto") else null;
    // libssl is built for QUIC's TLS API (-Dquic) but nothing links it yet: it is C++ and needs
    // V8's libc++ at the final link (docs/aws-lc.md).
    if (quic) if (aws_lc) |dep| b.getInstallStep().dependOn(&dep.artifact("aws_lc_ssl").step);
    // The C libraries every program that links the Rust library links too.
    var native_list: std.ArrayList(*std.Build.Step.Compile) = .empty;
    for ([_]?*std.Build.Step.Compile{ nghttp2_lib, aws_lc_crypto }) |lib| if (lib) |l| native_list.append(b.allocator, l) catch @panic("OOM");
    const native_libs = native_list.items;
    root.addImport("@io", io_module);
    root.addImport("@lz4", lz4_dep.module("@lz4"));
    const modules = hostModules(b, v8, io_module, lz4_dep.module("@lz4"), target, optimize, config);
    root.addImport("@managed", modules.managed);
    root.addImport("@engine", modules.engine);

    // The frozen-intrinsics snapshot is generated by running a tool built from the
    // same V8 archive, then embedded. Cross builds cannot run the tool and fall back
    // to V8's built-in seed.
    const build_options = b.addOptions();
    const embed_snapshot = target.query.isNative();
    // The snapshot provider object (see `snapshotProvider`); null when there is no blob.
    var provider: ?*std.Build.Step.Compile = null;
    build_options.addOption(bool, "has_snapshot", embed_snapshot);
    build_options.addOption(bool, "engine_snapshot_compressed", engine_snapshot == .compressed);
    build_options.addOption(bool, "v8_sandbox", v8_sandbox);
    // Debug snapshots are reproducible so a rebuild with unchanged inputs reuses them
    // Release keeps V8's default random seed.
    build_options.addOption(bool, "snapshot_seeded", optimize == .debug);
    build_options.addOption(u32, "snapshot_seed", 0x3c3d6918);
    root.addOptions("build_options", build_options);
    if (embed_snapshot) {
        const tool_module = b.createModule(.{
            .root_source_file = b.path("src/snapshot_tool.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = !external_link,
        });
        for ([_][]const u8{ "@v8", "@util", "@diagnostics" }) |name| tool_module.addImport(name, v8.module(name));
        tool_module.addImport("@io", io_module);
        tool_module.addImport("@lz4", lz4_dep.module("@lz4"));
        tool_module.addImport("@managed", modules.managed);
        tool_module.addImport("@engine", modules.engine);
        tool_module.addOptions("build_options", build_options);
        const tool = linkProgram(b, v8, target, optimize, external_link, "origine-snapshot", tool_module, rust_program, io_lib, lz4_lib, icu_lib, native_libs, null);
        const generate = std.Build.Step.Run.create(b, "generate engine snapshot");
        generate.addFileArg2(tool, .{});
        const blob = generate.addOutputFileArg2(if (engine_snapshot == .compressed) "engine.snapshot.lz4" else "engine.snapshot", .{});
        // LZ4-compressed (`lib/lz4`) when asked; main.zig expands it at startup.
        if (engine_snapshot == .compressed) generate.addArg("lz4");
        provider = snapshotProvider(b, target, optimize, blob, engine_snapshot == .compressed);
    }

    const binary = linkProgram(b, v8, target, optimize, external_link, "origine", root, rust_program, io_lib, lz4_lib, icu_lib, native_libs, provider);
    const install = b.addInstallBinFile(binary, "origine");
    b.getInstallStep().dependOn(&install.step);
    b.step("build-shell", "Build and install the REPL").dependOn(&install.step);
    const run = std.Build.Step.Run.create(b, "run origine");
    run.addFileArg2(binary, .{});
    run.addPassthruArgs();
    run.stdio = .inherit;
    b.step("run", "Run origine").dependOn(&run.step);
    b.step("shell", "Run the JS REPL").dependOn(&run.step);
    // One step that builds the native dependencies the Rust library and the host link against.
    const deps = b.step("deps", "Build the native dependencies (V8, mimalloc, ICU, AWS-LC, LZ4, nghttp2) and the Rust library");
    deps.dependOn(rust_build.step(rust, "build"));
    deps.dependOn(&v8.artifact("mimalloc").step);
    if (v8_prebuilt == null) deps.dependOn(&v8.artifact("v8_icu").step);
    if (aws_lc) |dep| deps.dependOn(dep.builder.getInstallStep());
    deps.dependOn(&lz4_lib.step);
    if (nghttp2_lib) |lib| deps.dependOn(&lib.step);
    const test_v8 = if (external_link) v8_build.dependency(b, v8_options, true) else v8;
    if (v8_prebuilt == null) b.step("build-v8", "Fetch, patch and rebuild V8; ordinary builds reuse the last archive").dependOn(&v8.builder.top_level_steps.get("build-v8").?.step);
    b.step("patch-v8", "Fetch V8 and apply the patch series without building").dependOn(&v8.builder.top_level_steps.get("patch-v8").?.step);
    // The I/O library has no V8 dependency and tests on its own.
    // Debug by default so the library's safety checks run; `src/safe.zig` is tested the same way.
    const io_test_module = b.createModule(.{
        .root_source_file = b.path("src/io/io.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    io_test_module.addImport("@safe", b.createModule(.{ .root_source_file = b.path("src/safe.zig"), .target = target, .optimize = optimize }));
    const io_tests = b.addTest(.{ .root_module = io_test_module });
    const safe_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/safe.zig"), .target = target, .optimize = optimize }) });
    const test_io_step = b.step("test-io", "Run the src/io library and src/safe.zig tests (no V8)");
    test_io_step.dependOn(&b.addRunArtifact(io_tests).step);
    test_io_step.dependOn(&b.addRunArtifact(safe_tests).step);
    const test_step = b.step("test", "Run the V8 package tests and the managed runtime tests");
    test_step.dependOn(&test_v8.builder.top_level_steps.get("test").?.step);

    const test_modules = hostModules(b, test_v8, io_module, lz4_dep.module("@lz4"), target, optimize, config);
    const test_root = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_root.addImport("@io", io_module);
    test_root.linkLibrary(io_lib);
    test_root.linkLibrary(lz4_lib);
    for (native_libs) |lib| test_root.linkLibrary(lib);
    test_step.dependOn(&lz4_dep.builder.top_level_steps.get("test").?.step);
    for ([_][]const u8{ "@v8", "@util", "@mimalloc" }) |name| {
        test_root.addImport(name, test_v8.module(name));
    }
    test_root.addImport("@managed", test_modules.managed);
    test_root.addImport("@engine", test_modules.engine);
    test_root.addObjectFile(rust_archive);
    const tests = b.addTest(.{ .root_module = test_root });
    if (optimize != .debug) {
        tests.use_llvm = true;
        if (target.result.os.tag != .macos) {
            tests.use_lld = true;
            tests.lto = .full;
        }
    }
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

/// How a blob is stored: as it is, or LZ4-compressed (lib/lz4).
const Embedding = enum { raw, compressed };

/// The I/O library's Zig API as a module (`src/io/io.zig`), always compiled in ReleaseFast. It
/// does not export the C ABI: that lives in `liborigine_io.a` (`ioLibrary`), so a program links
/// the archive exactly once. Borrows b through build teardown.
fn ioModule(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Module {
    const module = b.createModule(.{ .root_source_file = b.path("src/io/io.zig"), .target = target, .optimize = .fast, .link_libc = true });
    module.addImport("@safe", safeModule(b, target));
    return module;
}

/// Checks that survive ReleaseFast (`src/safe.zig`).
fn safeModule(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Module {
    return b.createModule(.{ .root_source_file = b.path("src/safe.zig"), .target = target, .optimize = .fast });
}

/// nghttp2 (lib/nghttp2), the sans-io HTTP/2 core, built ReleaseFast. Borrows b through build
/// teardown.
fn nghttp2Library(b: *std.Build, target: std.Build.ResolvedTarget) error{LazyDependencyNeeded}!*std.Build.Step.Compile {
    return (try b.dependencyLazy("nghttp2", .{ .target = target, .optimize = .fast })).artifact("nghttp2");
}

/// `liborigine_io.a`: the `oio_*` C ABI the Rust runtime calls, built once with LLVM in
/// ReleaseFast whatever `-Doptimize` says (the event loop is a hot path, and debug builds of the
/// host should not slow it down). Safety-critical invariants use `src/safe.zig`, which keeps its
/// checks in this mode. Every program that links the Rust library links this archive.
fn ioLibrary(b: *std.Build, target: std.Build.ResolvedTarget, io_module: *std.Build.Module) *std.Build.Step.Compile {
    const root = b.createModule(.{ .root_source_file = b.path("src/io/lib.zig"), .target = target, .optimize = .fast, .link_libc = true });
    root.addImport("@io", io_module);
    return b.addLibrary(.{ .name = "origine_io", .linkage = .static, .root_module = root, .use_llvm = true });
}

const HostModules = struct { engine: *std.Build.Module, managed: *std.Build.Module };

/// The engine snapshot as a link-level provider: a generated module that embeds `blob` and
/// exports `origine_snapshot_*` (see `src/snapshot_provider.zig`). Compiled as its own object so
/// the blob is not an input of the shell's compilation, and linked into every program that
/// restores the snapshot. Borrows b and blob through build teardown.
fn snapshotProvider(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, blob: std.Build.LazyPath, compressed: bool) *std.Build.Step.Compile {
    const files = b.addWriteFiles();
    _ = files.addCopyFile(blob, "engine.snapshot");
    const source = files.add("snapshot_provider.zig", b.fmt(
        \\const bytes = @embedFile("engine.snapshot");
        \\const blob: [bytes.len]u8 align(16) = bytes.*;
        \\pub export const origine_snapshot_present: bool = true;
        \\pub export const origine_snapshot_blob: [*]const u8 = &blob;
        \\pub export const origine_snapshot_len: usize = blob.len;
        \\pub export const origine_snapshot_compressed: bool = {s};
        \\
    , .{if (compressed) "true" else "false"}));
    const module = b.createModule(.{ .root_source_file = source, .target = target, .optimize = optimize });
    return b.addObject(.{ .name = "origine_snapshot_provider", .root_module = module });
}

/// Borrows b and dependency through build teardown; returns build-owned modules importing the
/// dependency's @v8 and @diagnostics. Retains no runtime state.
fn hostModules(b: *std.Build, dependency: *std.Build.Dependency, io_module: *std.Build.Module, lz4_module: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, config: *std.Build.Step.Options) HostModules {
    const engine = b.createModule(.{ .root_source_file = b.path("src/engine.zig"), .target = target, .optimize = optimize });
    const managed = b.createModule(.{ .root_source_file = b.path("src/managed.zig"), .target = target, .optimize = optimize });
    for ([_]*std.Build.Module{ engine, managed }) |module| {
        module.addImport("@v8", dependency.module("@v8"));
        module.addImport("@diagnostics", dependency.module("@diagnostics"));
    }
    // Embedding helpers (`eu.v` constructors, the process allocator) for the managed runtime and API.
    managed.addImport("@util", dependency.module("@util"));
    managed.addImport("@io", io_module);
    managed.addImport("@lz4", lz4_module);
    managed.addOptions("origine_config", config);
    return .{ .engine = engine, .managed = managed };
}

/// Builds `module` into an executable named `name`. On macOS non-debug builds this
/// compiles an object and links it with V8's matching ld64.lld (ThinLTO, ICF); other
/// builds use the Zig linker. Returns the build-owned binary path.
fn linkProgram(b: *std.Build, v8: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, external_link: bool, name: []const u8, module: *std.Build.Module, rust_lib: std.Build.LazyPath, io_lib: *std.Build.Step.Compile, lz4_lib: *std.Build.Step.Compile, icu_lib: ?*std.Build.Step.Compile, native_libs: []const *std.Build.Step.Compile, provider: ?*std.Build.Step.Compile) std.Build.LazyPath {
    if (external_link) {
        const object = b.addObject(.{ .name = name, .root_module = module, .use_llvm = true });
        // The external linker does not add Zig's compiler-rt; an object that needs a soft-float helper
        // (`__multf3`, `roundf128`, ... from f128 math in std) carries its own copy.
        object.bundle_compiler_rt = true;
        const link = b.addSystemCommand(&.{"/usr/bin/clang++"});
        // Keep the LLVM tool directory as a package-owned path.
        const linker = v8.namedLazyPath("clang_bin").path(b, "ld64.lld");
        link.addFileArg2(linker, .{ .prefix = "--ld-path=" });
        link.addArgs(&.{ "-target", b.fmt("{s}-apple-macos{f}", .{ @tagName(target.result.cpu.arch), target.result.os.version_range.semver.min }), "-o" });
        const binary = link.addOutputFileArg2(name, .{});
        link.addArtifactArg2(object, .{});
        link.addFileArg2(v8.namedLazyPath("v8"), .{});
        // The ICU data provider is its own link object (the archive refers to it); a prebuilt
        // archive brings its own.
        if (icu_lib) |lib| link.addArtifactArg2(lib, .{});
        link.addArtifactArg2(v8.artifact("mimalloc"), .{});
        link.addArtifactArg2(io_lib, .{});
        link.addArtifactArg2(lz4_lib, .{});
        for (native_libs) |lib| link.addArtifactArg2(lib, .{});
        if (provider) |p| link.addArtifactArg2(p, .{});
        link.addFileArg2(rust_lib, .{});
        link.addArgs(&.{ "-Wl,-dead_strip", "-Wl,--icf=all", "-Wl,-x", "-Wl,-w", "-Wl,-mllvm,-enable-merge-functions" });
        return binary;
    }
    module.addObjectFile(rust_lib);
    module.linkLibrary(io_lib);
    module.linkLibrary(lz4_lib);
    for (native_libs) |lib| module.linkLibrary(lib);
    if (provider) |p| module.addObjectFile(p.getEmittedBin());
    const exe = b.addExecutable(.{ .name = name, .root_module = module });
    if (optimize != .debug) {
        exe.use_llvm = true;
        exe.use_lld = true;
        exe.lto = .full;
    }
    return exe.getEmittedBin();
}
