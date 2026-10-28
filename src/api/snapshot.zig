//! `api.host.Snapshot`: heap snapshots the guest can make, keep, save and start isolates from.
//!
//! A `Record` is one snapshot in memory: either an init snapshot (`managed.init_snapshot.Image`: the
//! V8 blob of an evaluated init module graph plus the side table that restores its modules) or a bare
//! V8 blob (`fromRaw`). Records are reference counted so an isolate that was started from one keeps
//! it alive on its own thread, whatever the creator does with its handle.
const std = @import("std");
const v8 = @import("@v8");
const errno = @import("errno.zig");
const init_cache = @import("init_cache.zig");
const host_api = @import("host.zig");
const init_snapshot = @import("../managed/init_snapshot.zig");
const Host = host_api.Host;
const ScopeState = host_api.ScopeState;
const Call = @import("binding.zig").Call;

comptime {
    errno.requireBinding(create);
    errno.requireBinding(fromRaw);
    errno.requireBinding(fromFile);
    errno.requireBinding(blob);
    errno.requireBinding(file);
    errno.requireBinding(initOf);
    errno.requireBinding(close);
}

/// One snapshot in memory. Created with one reference; `release` frees it with the last one.
pub const Record = struct {
    alloc: std.mem.Allocator,
    refs: std.atomic.Value(u32) = .init(1),
    /// The init specifier of an init snapshot (null for a bare blob). Owned.
    init: ?[]u8 = null,
    image: ?init_snapshot.Image = null,
    /// A bare V8 blob (`fromRaw`). Owned.
    raw: ?[]align(16) u8 = null,

    /// The V8 blob an isolate boots from.
    pub fn blob(self: *const Record) []align(16) const u8 {
        if (self.image) |image| return image.blob;
        return self.raw.?;
    }

    /// Another reference; thread-safe.
    pub fn retain(self: *Record) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    /// Drops one reference; the last one frees the snapshot. Thread-safe.
    pub fn release(self: *Record) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        const alloc = self.alloc;
        if (self.image) |*image| image.deinit();
        if (self.raw) |raw| alloc.free(raw);
        if (self.init) |text| alloc.free(text);
        alloc.destroy(self);
    }
};

fn record(state: *ScopeState, id: u32) !*Record {
    const items = state.host.snapshots.items;
    if (id == 0 or id > items.len) return error.BadHandle;
    return items[id - 1] orelse error.BadHandle;
}

/// Stores `rec` in the host's table and returns its id (index + 1); frees `rec` on failure.
fn register(state: *ScopeState, rec: *Record) !u32 {
    const host = state.host;
    errdefer rec.release();
    try host.snapshots.append(host.allocator, rec);
    return @intCast(host.snapshots.items.len);
}

/// `native.snapshot.create(init)`: evaluates the module graph of `init` (a specifier, resolved as the
/// init module of the process is) in a throwaway isolate **on this thread**, which blocks it until
/// done, and returns the id of the resulting snapshot. The module graph is evaluated, not `main`.
/// `PermissionDenied` without the embedder's `isolates` (it supplies the engine snapshot the new
/// heap is built on), `InvalidData` for an init that throws or does not settle without I/O,
/// `Unsupported` for a graph a snapshot cannot carry.
pub fn create(state: *ScopeState, init: []const u8) errno.Error!u32 {
    return createImpl(state, init) catch |err| return switch (err) {
        error.InitFailed, error.InitNotSettled => error.InvalidData,
        error.NotSnapshottable => error.Unsupported,
        error.SnapshotFailed, error.InvalidSnapshot => error.Unexpected,
        else => errno.narrow(err),
    };
}

fn createImpl(state: *ScopeState, init: []const u8) !u32 {
    const host = state.host;
    const alloc = host.allocator;
    const config = host.isolates orelse return error.PermissionDenied;
    // The evaluation scope gets a host of its own: this one is in the middle of running a program.
    const scratch = try Host.create(alloc, .{
        .fs = host.fs,
        .runtime = host.runtime,
        .modules = host.modules,
        .transformers = host.transformers.entries,
    });
    defer scratch.destroy();
    const references = try scratch.externalReferences(alloc);
    defer alloc.free(references);
    var entry = try init_cache.entryFor(alloc, host, init);
    defer entry.deinit();
    var label: [128]u8 = undefined;
    var image = try init_snapshot.create(alloc, .{
        .key = entry.key,
        .identity = init_cache.identity(&label),
        .scope = scratch.initOptions(),
        .specifier = init,
        .source_hasher = init_cache.sourceHasher(scratch),
        .hooks = scratch.snapshotHooks(),
        .external_references = init_snapshot.referenceTable(references),
        .base_snapshot = config.engine_snapshot,
    });
    errdefer image.deinit();
    const rec = try alloc.create(Record);
    errdefer alloc.destroy(rec);
    rec.* = .{ .alloc = alloc, .init = try alloc.dupe(u8, init), .image = image };
    return register(state, rec);
}

/// `native.snapshot.fromRaw(bytes)`: a snapshot over a copy of a bare V8 blob. It has no module table,
/// so isolates started from it begin with the blob's heap and evaluate their init normally.
/// `InvalidData` for bytes V8 does not accept as a blob.
pub fn fromRaw(state: *ScopeState, bytes: []u8) errno.Error!u32 {
    return fromRawImpl(state, bytes) catch |err| return errno.narrow(err);
}

fn fromRawImpl(state: *ScopeState, bytes: []u8) !u32 {
    const alloc = state.host.allocator;
    if (bytes.len < 512) return error.InvalidData;
    const copy = try alloc.alignedAlloc(u8, init_snapshot.alignment, bytes.len);
    errdefer alloc.free(copy);
    @memcpy(copy, bytes);
    const startup: v8.StartupData = .{ .data = copy.ptr, .raw_size = @intCast(copy.len) };
    if (!startup.isValid()) return error.InvalidData;
    const rec = try alloc.create(Record);
    errdefer alloc.destroy(rec);
    rec.* = .{ .alloc = alloc, .raw = copy };
    return register(state, rec);
}

/// `native.snapshot.fromFile(bytes, init)`: a snapshot from the bytes of a cache snapshot
/// file made for `init` by this build (`file`). `InvalidData` for a damaged file, one made by another
/// build or for another init, or whose source files changed since; `Unsupported` for a packed file
/// when this build cannot unpack.
pub fn fromFile(state: *ScopeState, bytes: []u8, init: []const u8) errno.Error!u32 {
    return fromFileImpl(state, bytes, init) catch |err| return switch (err) {
        error.TruncatedFile, error.UnknownVersion, error.BadParity => error.InvalidData,
        error.UnsupportedFeature => error.Unsupported,
        error.BadSnapshotFile, error.FormatMismatch, error.EngineMismatch, error.KeyMismatch => error.InvalidData,
        else => errno.narrow(err),
    };
}

fn fromFileImpl(state: *ScopeState, bytes: []u8, init: []const u8) !u32 {
    const host = state.host;
    const alloc = host.allocator;
    const decoded = try init_cache.decodeFile(alloc, bytes);
    var entry = try init_cache.entryFor(alloc, host, init);
    defer entry.deinit();
    var label: [128]u8 = undefined;
    var image = init_snapshot.parse(alloc, decoded, entry.key, init_cache.identity(&label)) catch |err| {
        alloc.free(decoded);
        return err;
    };
    errdefer image.deinit();
    if (!image.sourcesUnchanged(init_cache.sourceHasher(host))) return error.InvalidData;
    const rec = try alloc.create(Record);
    errdefer alloc.destroy(rec);
    rec.* = .{ .alloc = alloc, .init = try alloc.dupe(u8, init), .image = image };
    return register(state, rec);
}

/// `native.snapshot.blob(id)`: a `Uint8Array` copy of the bare V8 blob.
pub fn blob(state: *ScopeState, call: *Call, id: u32) errno.Error!v8.Value {
    const rec = record(state, id) catch |err| return errno.narrow(err);
    return call.bytesValue(rec.blob()) catch |err| return errno.narrow(err);
}

/// `native.snapshot.file(id, compress)`: a `Uint8Array` with the bytes of the cache snapshot
/// file for this snapshot. `Unsupported` for a bare blob (it has no module table) and for `compress`
/// in a build without LZ4 snapshots.
pub fn file(state: *ScopeState, call: *Call, id: u32, compress: bool) errno.Error!v8.Value {
    const rec = record(state, id) catch |err| return errno.narrow(err);
    const image = rec.image orelse return error.Unsupported;
    const bytes = init_cache.encodeFile(state.host.allocator, &image, compress) catch |err| return errno.narrow(err);
    defer state.host.allocator.free(bytes);
    return call.bytesValue(bytes) catch |err| return errno.narrow(err);
}

/// `native.snapshot.init(id)`: the init specifier of an init snapshot, undefined for a bare blob.
pub fn initOf(state: *ScopeState, id: u32) errno.Error!?[]const u8 {
    const rec = record(state, id) catch |err| return errno.narrow(err);
    return rec.init;
}

/// `native.snapshot.close(id)`: drops the guest's reference. Isolates started from it keep theirs.
/// `BadHandle` for an unknown or already closed id.
pub fn close(state: *ScopeState, id: u32) errno.Error!void {
    const rec = record(state, id) catch |err| return errno.narrow(err);
    state.host.snapshots.items[id - 1] = null;
    rec.release();
}

/// The record for `id` with an extra reference for the caller to release (an isolate thread).
pub fn retained(state: *ScopeState, id: u32) !*Record {
    const rec = try record(state, id);
    rec.retain();
    return rec;
}
