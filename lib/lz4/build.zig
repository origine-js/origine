//! LZ4 (the pinned upstream release's `lz4.c` and `lz4hc.c`), built by the Zig build system, and
//! its Zig wrapper.
//!
//! Exposes the static library `lz4` (installed artifact) and the module `@lz4` (`src/lz4.zig`,
//! to be linked with the artifact by the consumer). The module is the only way in: the C ABI is
//! private to it.
//!
//! Options: `-Dtarget`, `-Doptimize`. The C code is meant for `ReleaseSmall`: the decoder is about
//! 1.5 KB and the HC compressor is only used by build-time tools (a final link drops it).
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const c_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .pic = true });
    c_module.addCSourceFiles(.{
        .root = b.dependency("source", .{}).path("lib"),
        .files = &.{ "lz4.c", "lz4hc.c" },
        .flags = &.{"-std=c99"},
    });
    const lib = b.addLibrary(.{ .name = "lz4", .linkage = .static, .root_module = c_module, .use_llvm = true });
    b.installArtifact(lib);

    _ = b.addModule("@lz4", .{
        .root_source_file = b.path("src/lz4.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/lz4.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_module.linkLibrary(lib);
    const test_step = b.step("test", "Test the wrapper against the library");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = test_module })).step);
}
