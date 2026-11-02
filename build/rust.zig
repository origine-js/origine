//! The Rust workspace (rust/, package `origine_rs`) as the root build sees it: the options the
//! root forwards and the package's outputs. The package owns the cargo invocation itself.

const std = @import("std");

pub const Options = struct {
    target: std.Build.ResolvedTarget,
    /// Comma-separated cargo features (`typescript,http,tls,dns,quic`).
    features: []const u8,
    offline: bool,
    /// The tree the vendored aws-lc-sys links (`lib/aws-lc`'s `prefix`), if `-Dtls`.
    aws_lc_prefix: ?std.Build.LazyPath,
    /// The host tree for the `clippy` step (the target one would be cross-compiled).
    aws_lc_host_prefix: ?std.Build.LazyPath,
    /// The V8 build outputs (null for a prebuilt V8, where cargo runs bare).
    v8: ?@import("v8.zig").RustPaths,
};

pub fn dependency(b: *std.Build, options: Options) error{LazyDependencyNeeded}!*std.Build.Dependency {
    const v8 = options.v8;
    return b.dependencyLazy("origine_rs", .{
        .target = options.target,
        .features = options.features,
        .cargo_offline = options.offline,
        .aws_lc_prefix = options.aws_lc_prefix,
        .aws_lc_host_prefix = options.aws_lc_host_prefix,
        .v8_archive = if (v8) |paths| paths.archive else null,
        .v8_mimalloc = if (v8) |paths| paths.mimalloc else null,
        .v8_icu = if (v8) |paths| paths.icu else null,
        .v8_root = if (v8) |paths| paths.root else null,
        .v8_compile_commands = if (v8) |paths| paths.compile_commands else null,
        .v8_binding = if (v8) |paths| paths.binding else null,
    });
}

/// A named top-level step of the package (`std.Build.Dependency` has no step accessor).
pub fn step(dep: *std.Build.Dependency, name: []const u8) *std.Build.Step {
    return &dep.builder.top_level_steps.get(name).?.step;
}
