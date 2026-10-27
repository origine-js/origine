//! Startup snapshot of finalized intrinsics and the host-independent API template.
//!
//! The engine's built-in seed snapshot is deliberately unfrozen, so every fresh
//! `Context::New` installs features and freezes the intrinsic graph (about 4 ms).
//! A snapshot created here is already finalized: restoring its default context
//! takes about 0.2 ms. Scope-specific state (scope pointer, security
//! token, import map) is never part of the snapshot; `Scope.create` adds it after
//! restore. API descriptors, capability methods and network classes are prepared
//! and frozen here; native authority is bound after restore. The blob depends on
//! the exact V8 build and patch set, so cache it only
//! under a key that changes when the engine binary changes.
//! Host-independent hardening helpers are retained as context data too; their
//! validation rules and process-specific validator callbacks are unchanged.
const std = @import("std");
const v8 = @import("@v8");
const api_glue = @import("../api/glue.zig");

/// Alignment V8 expects for snapshot data.
pub const alignment: std.mem.Alignment = .@"16";

/// Builds a startup snapshot with finalized intrinsics and a JS-only API template. V8 must already
/// be initialized. Runs a throwaway isolate on the calling thread. Returns bytes
/// owned by `allocator` (free with `allocator.free`); pass them to
/// `Runtime.Options.snapshot`, where they must outlive the Runtime.
pub fn create(allocator: std.mem.Allocator) ![]align(16) u8 {
    const aba = v8.ArrayBuffer.Allocator.initDefault();
    defer aba.deinit();
    var params = v8.Isolate.CreateParams.init();
    params.array_buffer_allocator = aba;
    const blob = make: {
        var creator: v8.SnapshotCreator = undefined;
        creator.init(&params);
        defer creator.deinit();
        const isolate = creator.getIsolate() orelse return error.SnapshotFailed;
        {
            var h_scope: v8.HandleScope = undefined;
            h_scope.init(isolate);
            defer h_scope.deinit();
            const context = v8.Context.init(isolate, null, null, null);
            context.enter();
            defer context.exit();
            const inventory = v8.Intrinsics.getObjects(context) orelse return error.SnapshotFailed;
            if (inventory.len() == 0) return error.SnapshotFailed;
            var timing: ?i64 = null;
            _ = try @import("bootstrap.zig").prepare(isolate, context, &timing);
            try api_glue.prepare(isolate, context);
            creator.setDefaultContext(context);
        }
        // CreateBlob must run outside all handle scopes.
        break :make creator.createBlob(.Clear);
    };
    defer blob.deinit();
    const bytes = blob.slice();
    if (bytes.len == 0) return error.SnapshotFailed;
    const owned = try allocator.alignedAlloc(u8, alignment, bytes.len);
    @memcpy(owned, bytes);
    return owned;
}
