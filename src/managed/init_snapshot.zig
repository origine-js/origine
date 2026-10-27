//! Startup snapshot of an evaluated init module graph.
//!
//! `create` evaluates the init module in a throwaway isolate (a V8 SnapshotCreator owns
//! its isolate, so the live runtime cannot be snapshotted) and serializes the heap with
//! the evaluated ES modules in it. `Image` is that result: an engine blob plus a side
//! table of what Zig memory must be rebuilt after restore (the `ModuleMap` entries, which
//! are not part of any V8 heap). Booting a `Runtime` from `Image.blob` and creating a
//! scope with `Scope.Options.init_snapshot = &image.table` yields a scope whose init graph
//! is already evaluated: importing it again hits the module map and runs nothing.
//!
//! The snapshot context holds no live host state or API native callbacks. It carries a
//! private JS-only API template (descriptors, methods and classes) with no native authority;
//! Host.install binds it after restore. The default context keeps the same pristine
//! template and frozen intrinsics, so each restored scope gets independent state.
const std = @import("std");
const v8 = @import("@v8");
const Runtime = @import("runtime.zig").Runtime;
const Scope = @import("scope.zig").Scope;
const ImportAttribute = @import("module_types.zig").ImportAttribute;
const print_binding = @import("print.zig");
const api_glue = @import("../api/glue.zig");

pub const alignment: std.mem.Alignment = .@"16";
pub const hash_len = 32;
const magic = "ORISNAP\x01";

/// What a file must have been made by, stored in its header in readable form so a file from
/// another build is refused with a reason (and so a future reader can tell what wrote it)
/// before anything else in it is trusted.
pub const Identity = struct {
    /// Layout version of the file and of what its key covers; the host bumps it on changes.
    format: u32 = 1,
    /// Names the V8 build and flags that made the blob (V8 refuses blobs from any other).
    engine: []const u8 = "",
};

/// Native callbacks that live in a snapshotted heap. V8 maps them to table positions at
/// serialization time, so the isolate that restores the blob must be given this exact
/// table (every isolate this library creates passes it). Append only; reordering or
/// removing an entry invalidates existing blobs. Null-terminated.
/// The references managed's own heap objects need; hosts with native callbacks of their own
/// append to these (see `Host.externalReferences`) and null-terminate.
pub const base_references = [_]?*const anyopaque{
    @ptrCast(&print_binding.callback),
};
const default_references = base_references ++ [_]?*const anyopaque{null};

/// The table V8 expects in `CreateParams.external_references` when the host adds none.
/// Static; never freed.
pub fn externalReferences() *const isize {
    return @ptrCast(&default_references[0]);
}

/// `CreateParams.external_references` for a null-terminated `table` (borrowed: it must outlive
/// every isolate made with it).
pub fn referenceTable(table: []const ?*const anyopaque) *const isize {
    std.debug.assert(table.len > 0 and table[table.len - 1] == null);
    return @ptrCast(&table[0]);
}

/// One module of the serialized graph.
pub const Module = struct {
    /// Canonical module ID (the module map key's first component).
    id: []const u8,
    /// Normalized (sorted) import attributes.
    attributes: []const ImportAttribute,
    /// Index of the `v8.Module` in the snapshotted context's data.
    data_index: usize,
    /// Static dependencies, as the module requested them.
    dependencies: []const Dependency,
    /// Hash of the module's source file as the host reported it at creation, or null for
    /// modules the host vouches for another way (embedded ones).
    source_hash: ?[hash_len]u8 = null,
};
pub const Dependency = struct {
    specifier: []const u8,
    /// Index into `Table.modules`.
    module: u32,
};

/// What `Scope.create` needs to restore the init scope. Slices are borrowed from the Image.
pub const Table = struct {
    /// `Context.fromSnapshot` index of the init context.
    context_index: usize,
    /// Context data indices of the bootstrap helper functions.
    hardener_index: usize,
    unsupported_index: usize,
    modules: []const Module,
};

/// Lets the host vouch for module sources: returns a hash of whatever the module ID is
/// read from (changes when the module changes), or null for modules whose content is
/// fixed by the engine build. Borrows `id` for the call.
pub const SourceHasher = struct {
    data: ?*anyopaque = null,
    hash: *const fn (data: ?*anyopaque, id: []const u8) anyerror!?[hash_len]u8,
};

/// A parsed snapshot file. Owns `bytes`; `table` and `blob` point into it (and into
/// `arena`). Must outlive every Runtime created from `blob`.
pub const Image = struct {
    alloc: std.mem.Allocator,
    bytes: []align(16) u8,
    arena: std.heap.ArenaAllocator,
    key: [hash_len]u8,
    table: Table,
    blob: []align(16) const u8,

    /// Frees the file bytes and everything parsed from them.
    pub fn deinit(self: *Image) void {
        self.arena.deinit();
        self.alloc.free(self.bytes);
        self.* = undefined;
    }

    /// Whether every vouched module still hashes as it did at creation. A hasher error or
    /// a missing source counts as changed. Borrows the hasher for the call.
    pub fn sourcesUnchanged(self: *const Image, hasher: SourceHasher) bool {
        for (self.table.modules) |module| {
            const recorded = module.source_hash orelse continue;
            const current = hasher.hash(hasher.data, module.id) catch return false;
            if (current == null or !std.mem.eql(u8, &current.?, &recorded)) return false;
        }
        return true;
    }
};

pub const ParseError = error{ BadSnapshotFile, FormatMismatch, EngineMismatch, KeyMismatch } || std.mem.Allocator.Error;

/// Takes ownership of `bytes` on success only (allocated with `alloc`). The file must have
/// been written by `create` with the same `identity` and `key`; anything else is rejected,
/// with the first thing that differs as the error, without V8 seeing it. Files are never
/// migrated: a blob only fits the V8 build that made it. Borrows identity for the call.
pub fn parse(alloc: std.mem.Allocator, bytes: []align(16) u8, key: [hash_len]u8, identity: Identity) ParseError!Image {
    var reader: Reader = .{ .bytes = bytes };
    if (!std.mem.eql(u8, try reader.take(magic.len), magic)) return error.BadSnapshotFile;
    if (try reader.int() != identity.format) return error.FormatMismatch;
    if (!std.mem.eql(u8, try reader.string(), identity.engine)) return error.EngineMismatch;
    const stored_key = (try reader.take(hash_len))[0..hash_len].*;
    if (!std.mem.eql(u8, &stored_key, &key)) return error.KeyMismatch;
    var arena: std.heap.ArenaAllocator = .init(alloc);
    errdefer arena.deinit();
    const a = arena.allocator();
    const context_index = try reader.int();
    const hardener_index = try reader.int();
    const unsupported_index = try reader.int();
    const count = try reader.int();
    if (count > bytes.len) return error.BadSnapshotFile;
    const modules = try a.alloc(Module, count);
    for (modules) |*module| {
        module.id = try reader.string();
        const attribute_count = try reader.int();
        if (attribute_count > bytes.len) return error.BadSnapshotFile;
        const attributes = try a.alloc(ImportAttribute, attribute_count);
        for (attributes) |*attribute| attribute.* = .{ .key = try reader.string(), .value = try reader.string() };
        module.attributes = attributes;
        module.data_index = try reader.int();
        const has_hash = (try reader.take(1))[0];
        module.source_hash = if (has_hash == 1) (try reader.take(hash_len))[0..hash_len].* else null;
        const dependency_count = try reader.int();
        if (dependency_count > bytes.len) return error.BadSnapshotFile;
        const dependencies = try a.alloc(Dependency, dependency_count);
        for (dependencies) |*dependency| {
            dependency.specifier = try reader.string();
            const target = try reader.int();
            if (target >= count) return error.BadSnapshotFile;
            dependency.module = @intCast(target);
        }
        module.dependencies = dependencies;
    }
    const blob_len = try reader.int();
    // The blob starts on a 16-byte boundary relative to the (16-aligned) file start.
    reader.offset = std.mem.alignForward(usize, reader.offset, 16);
    const blob = try reader.take(blob_len);
    return .{
        .alloc = alloc,
        .bytes = bytes,
        .arena = arena,
        .key = key,
        .table = .{ .context_index = context_index, .hardener_index = hardener_index, .unsupported_index = unsupported_index, .modules = modules },
        .blob = @alignCast(blob),
    };
}

const Reader = struct {
    bytes: []const u8,
    offset: usize = 0,

    fn take(self: *Reader, len: usize) error{BadSnapshotFile}![]const u8 {
        const end = std.math.add(usize, self.offset, len) catch return error.BadSnapshotFile;
        if (end > self.bytes.len) return error.BadSnapshotFile;
        defer self.offset = end;
        return self.bytes[self.offset..end];
    }
    fn int(self: *Reader) error{BadSnapshotFile}!usize {
        return std.math.cast(usize, std.mem.readInt(u64, (try self.take(8))[0..8], .little)) orelse error.BadSnapshotFile;
    }
    fn string(self: *Reader) error{BadSnapshotFile}![]const u8 {
        return self.take(try self.int());
    }
};

fn writeInt(list: *std.ArrayList(u8), alloc: std.mem.Allocator, value: usize) !void {
    var buffer: [8]u8 = undefined;
    std.mem.writeInt(u64, &buffer, value, .little);
    try list.appendSlice(alloc, &buffer);
}
fn writeString(list: *std.ArrayList(u8), alloc: std.mem.Allocator, value: []const u8) !void {
    try writeInt(list, alloc, value.len);
    try list.appendSlice(alloc, value);
}

/// Serializes the side table and blob into one 16-byte-aligned buffer owned by `alloc`.
fn serialize(alloc: std.mem.Allocator, identity: Identity, key: [hash_len]u8, table: Table, blob: []const u8) ![]align(16) u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(alloc);
    try list.appendSlice(alloc, magic);
    try writeInt(&list, alloc, identity.format);
    try writeString(&list, alloc, identity.engine);
    try list.appendSlice(alloc, &key);
    try writeInt(&list, alloc, table.context_index);
    try writeInt(&list, alloc, table.hardener_index);
    try writeInt(&list, alloc, table.unsupported_index);
    try writeInt(&list, alloc, table.modules.len);
    for (table.modules) |module| {
        try writeString(&list, alloc, module.id);
        try writeInt(&list, alloc, module.attributes.len);
        for (module.attributes) |attribute| {
            try writeString(&list, alloc, attribute.key);
            try writeString(&list, alloc, attribute.value);
        }
        try writeInt(&list, alloc, module.data_index);
        if (module.source_hash) |hash| {
            try list.append(alloc, 1);
            try list.appendSlice(alloc, &hash);
        } else try list.append(alloc, 0);
        try writeInt(&list, alloc, module.dependencies.len);
        for (module.dependencies) |dependency| {
            try writeString(&list, alloc, dependency.specifier);
            try writeInt(&list, alloc, dependency.module);
        }
    }
    try writeInt(&list, alloc, blob.len);
    try list.appendNTimes(alloc, 0, std.mem.alignForward(usize, list.items.len, 16) - list.items.len);
    try list.appendSlice(alloc, blob);
    const out = try alloc.alignedAlloc(u8, alignment, list.items.len);
    @memcpy(out, list.items);
    return out;
}

/// Host callbacks around the evaluation scope: the one place a host can give init-time natives
/// state that exists only while the snapshot is being made.
pub const Hooks = struct {
    data: ?*anyopaque = null,
    /// Runs once the scope exists, before the init module is imported.
    attach: *const fn (data: ?*anyopaque, scope: *Scope) anyerror!void,
    /// Runs when evaluation is over (also after a failure), before the heap is serialized, with
    /// the isolate alive: release whatever `attach` made, clear any process pointer it stored
    /// in the scope's context.
    detach: *const fn (data: ?*anyopaque, scope: *Scope) void,
};

pub const CreateOptions = struct {
    /// Identifies what the snapshot is valid for; stored in the file and checked by `parse`.
    key: [hash_len]u8,
    /// Written to the file header and required again by `parse`.
    identity: Identity = .{},
    /// Resolver, loader and import map for the evaluation scope. The loader must return
    /// plain `source` content; a `meta` hook may be set but receives the creation scope. Leave
    /// `code_cache` unset: V8 cannot produce code caches inside a snapshot creator, and caches
    /// made by an isolate booted from another blob are refused (see `Scope.Options.code_cache`).
    scope: Scope.Options,
    /// Specifier of the init module, as the host will import it after restore.
    specifier: []const u8,
    source_hasher: ?SourceHasher = null,
    hooks: ?Hooks = null,
    /// The external-reference table (`referenceTable`) of the host's native callbacks. The
    /// runtime that restores the blob must be created with the same table.
    external_references: ?*const isize = null,
    /// Frozen-intrinsics engine snapshot (see `snapshot.create`) to build on, which makes
    /// creation faster and the result identical to a normal start. Borrowed through return.
    base_snapshot: ?[]align(16) const u8 = null,
};

pub const CreateError = error{
    /// The init promise did not settle from microtasks alone (pending I/O, timers).
    InitNotSettled,
    /// The init module or a dependency threw or failed to load.
    InitFailed,
    /// The graph holds something a snapshot cannot carry (synthetic module, failure).
    NotSnapshottable,
    SnapshotFailed,
    InvalidSnapshot,
};

/// Evaluates `options.specifier` and returns the serialized result. V8 must be initialized.
/// Borrows options (and the callbacks' data) through return; runs the loader on the calling
/// thread. Everything it creates is released before it returns, whether it succeeds or not.
pub fn create(alloc: std.mem.Allocator, options: CreateOptions) !Image {
    const aba = v8.ArrayBuffer.Allocator.initDefault();
    defer aba.deinit();
    var params = v8.Isolate.CreateParams.init();
    params.array_buffer_allocator = aba;
    params.external_references = options.external_references orelse externalReferences();
    var base: v8.StartupData = .{ .data = null, .raw_size = 0 };
    if (options.base_snapshot) |bytes| {
        if (bytes.len < 512) return error.InvalidSnapshot;
        base = .{ .data = bytes.ptr, .raw_size = @intCast(bytes.len) };
        if (!base.isValid()) return error.InvalidSnapshot;
        params.snapshot_blob = &base;
    }
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    var table: Table = undefined;
    const blob = make: {
        var creator: v8.SnapshotCreator = undefined;
        creator.init(&params);
        defer creator.deinit();
        const isolate = creator.getIsolate() orelse return error.SnapshotFailed;
        {
            const rt = try Runtime.createInCreator(alloc, isolate, aba);
            var live = true;
            defer if (live) rt.destroy();
            table = try evaluate(rt, &creator, arena.allocator(), options);
            live = false;
            // Every persistent handle must be gone before the heap is serialized.
            rt.destroy();
        }
        // CreateBlob must run outside all handle scopes.
        break :make creator.createBlob(.Clear);
    };
    defer blob.deinit();
    if (blob.slice().len == 0) return error.SnapshotFailed;
    const bytes = try serialize(alloc, options.identity, options.key, table, blob.slice());
    errdefer alloc.free(bytes);
    return parse(alloc, bytes, options.key, options.identity) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.SnapshotFailed,
    };
}

/// Builds the init scope in `rt`, evaluates the init module and registers everything the
/// restored scope needs with `creator`. Returned slices live in `alloc` (an arena).
fn evaluate(rt: *Runtime, creator: *v8.SnapshotCreator, alloc: std.mem.Allocator, options: CreateOptions) !Table {
    const isolate = rt.isolate;
    {
        // The default context of the blob stays the pristine frozen one.
        var session: Runtime.Session = undefined;
        session.init(rt);
        defer session.deinit();
        const ctx = v8.Context.init(isolate, null, null, null);
        ctx.enter();
        defer ctx.exit();
        var timing: ?i64 = null;
        _ = try @import("bootstrap.zig").prepare(isolate, ctx, &timing);
        try api_glue.prepare(isolate, ctx);
        creator.setDefaultContext(ctx);
    }
    const scope = try rt.createScope(options.scope);
    {
        var session: Scope.Session = undefined;
        session.init(scope);
        defer session.deinit();
        try api_glue.prepare(isolate, session.ctx);
    }
    if (options.hooks) |hooks| try hooks.attach(hooks.data, scope);
    defer if (options.hooks) |hooks| hooks.detach(hooks.data, scope);
    {
        const loading = try scope.importModule(options.specifier, null);
        defer loading.deinit();
        rt.pump();
        var session: Runtime.Session = undefined;
        session.init(rt);
        defer session.deinit();
        switch (loading.deref().state()) {
            .Pending => return error.InitNotSettled,
            .Rejected => return error.InitFailed,
            .Fulfilled => {},
        }
    }
    var scope_session: Scope.Session = undefined;
    scope_session.init(scope);
    defer scope_session.deinit();
    const ctx = scope_session.ctx;
    const modules = try scope.module_map.snapshotModules(alloc, creator);
    if (options.source_hasher) |hasher| for (modules) |*module| {
        module.source_hash = try hasher.hash(hasher.data, module.id);
    };
    const context_index = creator.addContext(ctx);
    const hardener_index = creator.addDataToContext(ctx, scope.hardener.deref().object.value.data);
    const unsupported_index = creator.addDataToContext(ctx, scope.unsupported_prototype.deref().object.value.data);
    // The scope pointer is process memory; the restored scope installs its own.
    ctx.setAlignedPointerInEmbedderData(1, null);
    return .{ .context_index = context_index, .hardener_index = hardener_index, .unsupported_index = unsupported_index, .modules = modules };
}
