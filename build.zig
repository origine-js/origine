const std = @import("std");

/// Borrows b and its configuration through build teardown; creates build-owned
/// dependency modules, cached artifacts and install/run/test steps. Retains no runtime state.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const external_link = target.result.os.tag == .macos and optimize != .debug;
    // Release V8 by default; a debug V8 compiles faster and is for working on V8 patches.
    const v8_debug = b.option(bool, "v8_debug", "Build V8 in debug mode for quick iteration on V8 patches (default: release V8)") orelse false;
    // V8 always builds from source (patches apply automatically, ninja makes it incremental);
    // an explicit archive skips that.
    const prebuilt: ?[]const u8 = b.option([]const u8, "prebuilt_v8_path", "Path to a prebuilt V8 archive");
    const clang_bin = b.option([]const u8, "v8_clang_dir", "Matching V8 LLVM bin directory") orelse "";
    const cache_root = b.option([]const u8, "cache_root", "V8 checkout and toolchain cache") orelse
        (b.root.joinString(b.allocator, "lib/v8_zig/.lp-cache") catch @panic("OOM"));
    const options: V8Options = .{ .target = target, .v8_debug = v8_debug, .prebuilt = prebuilt, .clang_bin = clang_bin, .cache_root = cache_root };
    const v8 = v8Dependency(b, options, !external_link);
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
    const modules = hostModules(b, v8, target, optimize);
    root.addImport("@managed", modules.managed);
    root.addImport("@engine", modules.engine);

    var binary: std.Build.LazyPath = undefined;
    if (external_link) {
        const object = b.addObject(.{ .name = "origine", .root_module = root, .use_llvm = true });
        const link = b.addSystemCommand(&.{"/usr/bin/clang++"});
        // Keep the LLVM tool directory as a package-owned path.
        const linker = v8.namedLazyPath("clang_bin").path(b, "ld64.lld");
        link.addPrefixedFileArg("--ld-path=", linker);
        link.addArgs(&.{ "-target", b.fmt("{s}-apple-macos{f}", .{ @tagName(target.result.cpu.arch), target.result.os.version_range.semver.min }), "-o" });
        binary = link.addOutputFileArg("origine");
        link.addArtifactArg(object);
        link.addFileArg(v8.namedLazyPath("v8"));
        link.addArtifactArg(v8.artifact("mimalloc"));
        link.addArgs(&.{ "-Wl,-dead_strip", "-Wl,--icf=all", "-Wl,-x", "-Wl,-w", "-Wl,-mllvm,-enable-merge-functions" });
    } else {
        const exe = b.addExecutable(.{ .name = "origine", .root_module = root });
        if (optimize != .debug) {
            exe.use_llvm = true;
            exe.use_lld = true;
            exe.lto = .full;
        }
        binary = exe.getEmittedBin();
    }

    const install = b.addInstallBinFile(binary, "origine");
    b.getInstallStep().dependOn(&install.step);
    b.step("build-shell", "Build and install the REPL").dependOn(&install.step);
    const run = std.Build.Step.Run.create(b, "run origine");
    run.addFileArg(binary);
    run.addPassthruArgs();
    run.stdio = .inherit;
    b.step("run", "Run origine").dependOn(&run.step);
    b.step("shell", "Run the JS REPL").dependOn(&run.step);
    const test_v8 = if (external_link) v8Dependency(b, options, true) else v8;
    b.step("patch-v8", "Fetch V8 and apply the patch series without building").dependOn(&v8.builder.top_level_steps.get("patch-v8").?.step);
    const test_step = b.step("test", "Run the V8 package tests and the managed runtime tests");
    test_step.dependOn(&test_v8.builder.top_level_steps.get("test").?.step);

    const test_modules = hostModules(b, test_v8, target, optimize);
    const test_root = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    for ([_][]const u8{ "@v8", "@util", "@mimalloc" }) |name| {
        test_root.addImport(name, test_v8.module(name));
    }
    test_root.addImport("@managed", test_modules.managed);
    test_root.addImport("@engine", test_modules.engine);
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

const V8Options = struct {
    target: std.Build.ResolvedTarget,
    v8_debug: bool,
    prebuilt: ?[]const u8,
    clang_bin: []const u8,
    cache_root: []const u8,
};

/// Borrows b and options, including nested path strings, through build teardown.
/// Returns a build-owned dependency valid through teardown; retains no runtime resources.
fn v8Dependency(b: *std.Build, options: V8Options, link_native: bool) *std.Build.Dependency {
    return if (options.prebuilt) |path| b.dependency("v8", .{
        .target = options.target,
        .optimize = .fast,
        .v8_debug = options.v8_debug,
        .link_native = link_native,
        .prebuilt_v8_path = path,
        .v8_clang_dir = options.clang_bin,
    }) else b.dependency("v8", .{
        .target = options.target,
        .optimize = .fast,
        .v8_debug = options.v8_debug,
        .link_native = link_native,
        .cache_root = options.cache_root,
        .v8_clang_dir = options.clang_bin,
    });
}

const HostModules = struct { engine: *std.Build.Module, managed: *std.Build.Module };

/// Borrows b and dependency through build teardown; returns build-owned modules importing the
/// dependency's @v8 and @diagnostics. Retains no runtime state.
fn hostModules(b: *std.Build, dependency: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) HostModules {
    const engine = b.createModule(.{ .root_source_file = b.path("src/engine.zig"), .target = target, .optimize = optimize });
    const managed = b.createModule(.{ .root_source_file = b.path("src/managed.zig"), .target = target, .optimize = optimize });
    for ([_]*std.Build.Module{ engine, managed }) |module| {
        module.addImport("@v8", dependency.module("@v8"));
        module.addImport("@diagnostics", dependency.module("@diagnostics"));
    }
    return .{ .engine = engine, .managed = managed };
}
