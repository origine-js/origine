//! nghttp2 (the pinned upstream release's `lib/`), built by the Zig build system.
//!
//! Exposes the static library `nghttp2` (installed artifact) and installs its headers. Only the
//! sans-io C library is built: no sockets, no TLS, no loop; the session is driven with
//! `nghttp2_session_mem_recv2` / `nghttp2_session_mem_send2` by the Rust crate that binds it.
//!
//! Options: `-Dtarget`, `-Doptimize`. HPACK and framing sit on the request path, so the default
//! consumer builds it ReleaseFast.
const std = @import("std");

const sources = [_][]const u8{
    "nghttp2_alpn.c",            "nghttp2_buf.c",    "nghttp2_callbacks.c",     "nghttp2_debug.c",
    "nghttp2_extpri.c",          "nghttp2_frame.c",  "nghttp2_hd.c",            "nghttp2_hd_huffman.c",
    "nghttp2_hd_huffman_data.c", "nghttp2_helper.c", "nghttp2_http.c",          "nghttp2_map.c",
    "nghttp2_mem.c",             "nghttp2_option.c", "nghttp2_outbound_item.c", "nghttp2_pq.c",
    "nghttp2_priority_spec.c",   "nghttp2_queue.c",  "nghttp2_ratelim.c",       "nghttp2_rcbuf.c",
    "nghttp2_session.c",         "nghttp2_stream.c", "nghttp2_submit.c",        "nghttp2_time.c",
    "nghttp2_version.c",         "sfparse.c",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const source = b.dependency("source", .{});

    const module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .pic = true });
    module.addCSourceFiles(.{
        .root = source.path("lib"),
        .files = &sources,
        .flags = &.{"-std=gnu99"},
    });
    module.addIncludePath(source.path("lib"));
    module.addIncludePath(source.path("lib/includes"));
    module.addCMacro("NGHTTP2_STATICLIB", "1");
    module.addCMacro("HAVE_NETINET_IN", "1");
    module.addCMacro("HAVE_TIME_H", "1");
    if (target.result.os.tag != .windows) {
        module.addCMacro("HAVE_ARPA_INET_H", "1");
        module.addCMacro("HAVE_UNISTD_H", "1");
    }

    const lib = b.addLibrary(.{ .name = "nghttp2", .linkage = .static, .root_module = module, .use_llvm = true });
    lib.installHeadersDirectory(source.path("lib/includes/nghttp2"), "nghttp2", .{});
    b.installArtifact(lib);
}
