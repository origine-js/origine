//! mimalloc, built by the Zig build system from the pinned upstream release plus the patch
//! series in `patches/`, and its Zig bindings.
//!
//! Exposes the static library `mimalloc` (installed artifact) and the module `@mimalloc`
//! (`src/mimalloc.zig`, to be linked with the artifact by the consumer).
//!
//! Options: `-Dtarget`, `-Doptimize`, `-Dlto` (full LTO through lld; the consumer decides,
//! because Darwin links convert bitcode itself), `-Dopt_arch` (upstream's MI_OPT_ARCH).
const std = @import("std");

/// Applied in order to a copy of the pinned source (`tools/patch.zig`).
const patches = [_][]const u8{
    "0001-enable-arena-unload.patch",
    "0002-no-cache-for-arena-theaps.patch",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lto = b.option(bool, "lto", "Link-time optimize the library with lld (default: off)") orelse false;
    const opt_arch = b.option(bool, "opt_arch", "MI_OPT_ARCH: compile for a newer CPU baseline in optimized builds (default: on)") orelse true;

    const patch_tool = b.addExecutable(.{
        .name = "patch",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/patch.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });
    const patch = b.addRunArtifact(patch_tool);
    patch.addDirectoryArg(b.dependency("source", .{}).path(""));
    const source = patch.addOutputDirectoryArg("mimalloc");
    for (patches) |name| patch.addFileArg(b.path(b.fmt("patches/{s}", .{name})));

    const c_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .pic = true });
    c_module.addIncludePath(source.path(b, "include"));
    var flags: std.ArrayList([]const u8) = .empty;
    flags.appendSlice(b.allocator, &.{ "-std=c11", "-DMI_STATIC_LIB", "-DMI_OSX_ZONE=0", "-DMI_OSX_INTERPOSE=0" }) catch @panic("OOM");
    if (opt_arch and optimize != .debug) flags.appendSlice(b.allocator, optArchFlags(target.result)) catch @panic("OOM");
    c_module.addCSourceFile(.{ .file = source.path(b, "src/static.c"), .flags = flags.items });
    if (target.result.os.tag == .windows) {
        for ([_][]const u8{ "psapi", "shell32", "user32", "advapi32", "bcrypt" }) |name| c_module.linkSystemLibrary(name, .{});
    } else if (target.result.os.tag == .linux) {
        c_module.linkSystemLibrary("pthread", .{});
    }
    // Links only mi_* APIs; libc symbols and macOS malloc zones are not overridden.
    const lib = b.addLibrary(.{ .name = "mimalloc", .linkage = .static, .root_module = c_module });
    if (optimize != .debug) {
        lib.use_llvm = true;
        if (lto) {
            lib.use_lld = true;
            lib.lto = .full;
        }
    }
    b.installArtifact(lib);

    _ = b.addModule("@mimalloc", .{
        .root_source_file = b.path("src/mimalloc.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const test_step = b.step("test", "Test the bindings (against the patched library) and the patch tool");
    const tool_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tools/patch.zig"),
        .target = b.graph.host,
    }) });
    test_step.dependOn(&b.addRunArtifact(tool_tests).step);

    const binding_module = b.createModule(.{
        .root_source_file = b.path("src/mimalloc.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    binding_module.linkLibrary(lib);
    // Static asserts on the C header: the Zig option numbers and size constants must match it.
    binding_module.addIncludePath(source.path(b, "include"));
    binding_module.addCSourceFile(.{ .file = b.path("tests/abi.c"), .flags = &.{"-std=c11"} });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = binding_module })).step);
}

/// What upstream's CMake adds for MI_OPT_ARCH=ON (CMakeLists.txt, "Compiler and architecture
/// specific flags"): a baseline with fast atomics, bit scans and load-acquire. None for other
/// architectures. The x86-64 flags need a Haswell (2013) or newer CPU.
fn optArchFlags(target: std.Target) []const []const u8 {
    return switch (target.cpu.arch) {
        // Apple Silicon has armv8.3-a (LDAPR); elsewhere armv8.1-a (LSE atomics).
        .aarch64 => if (target.os.tag.isDarwin()) &.{"-march=armv8.3-a"} else &.{"-march=armv8.1-a"},
        .arm => &.{"-march=armv8.1-a"},
        .x86_64 => &.{ "-march=haswell", "-mavx2" },
        .riscv64 => &.{"-march=rv64gcb_zacas"},
        .riscv32 => &.{"-march=rv32gcb_zacas"},
        else => &.{},
    };
}
