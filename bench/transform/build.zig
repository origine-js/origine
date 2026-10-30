const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const util = b.createModule(.{ .root_source_file = b.path("vendor/yuku/src/util/root.zig"), .target = target, .optimize = optimize });
    const spec = b.createModule(.{ .root_source_file = b.path("vendor/yuku/src/spec/root.zig"), .target = target, .optimize = optimize });
    spec.addImport("util", util);
    const options = b.addOptions();
    options.addOption(bool, "source_maps", true);
    const parser = b.createModule(.{ .root_source_file = b.path("vendor/yuku/src/parser/root.zig"), .target = target, .optimize = optimize });
    parser.addImport("util", util);
    parser.addImport("spec", spec);
    parser.addImport("codegen_options", options.createModule());
    parser.addImport("dialect", b.addOptions().createModule());
    spec.addImport("parser", parser);
    const root = b.createModule(.{ .root_source_file = b.path("yuku.zig"), .target = target, .optimize = optimize, .link_libc = true, .strip = true });
    root.addImport("parser", parser);
    b.installArtifact(b.addLibrary(.{ .name = "bench_yuku", .linkage = .dynamic, .root_module = root }));
    b.installArtifact(b.addLibrary(.{ .name = "bench_yuku_static", .linkage = .static, .root_module = root }));
}
