//! A module `Loader` backed by a JS callback: `loader(moduleId) => source | { source }`
//! (or a promise of either). The callback runs in the creating scope's realm; its
//! result is copied into the child as module source, after the child's extension-keyed
//! transformers (api.scope.create `transformers`) have run on it.
const std = @import("std");
const v8 = @import("@v8");
const eu = @import("@util");
const binding = @import("binding.zig");
const Runtime = @import("../managed/runtime.zig").Runtime;
const Scope = @import("../managed/scope.zig").Scope;
const module_types = @import("../managed/module_types.zig");
const json_module = @import("json_module.zig");
const host_mod = @import("host.zig");
const Host = host_mod.Host;
const transformer = @import("transform/transformer.zig");
const transform_handle = @import("transform/handle.zig");

/// A guest-written transformer `(source, id) => string | { source }`, run in the parent realm.
const JsTransformer = struct {
    loader: *JsLoader,
    function: v8.Global.Of(v8.Function),
};

/// Most `[extension, transformer]` pairs one child may have.
pub const max_transformers = 64;
/// Longest extension, in UTF-8 bytes, a transformer map accepts.
const max_extension_len = 64;

pub const JsLoader = struct {
    host: *Host,
    parent: *Scope,
    function: v8.Global.Of(v8.Function),
    /// This child's extension map. `entries[i].ext` is `exts[i]`; JS entries point into `js`.
    /// All host-allocator storage owned by the loader; set once by `setTransformers`.
    entries: []transformer.Entry = &.{},
    exts: [][]u8 = &.{},
    js: []JsTransformer = &.{},
    /// Loads whose promise has not settled yet. Freed by `fulfilled`/`rejected` as they run,
    /// or by `deinit` for any that never will.
    pendings: std.ArrayList(*Pending) = .empty,

    /// Releases the loader function, the transformer functions, unsettled loads and all
    /// storage. Call once, before `Runtime.destroy`.
    pub fn deinit(self: *JsLoader) void {
        const alloc = self.host.allocator;
        self.function.deinit();
        for (self.js) |*entry| entry.function.deinit();
        // A pending load's promise handlers still point at its record, and the guest's promise
        // may settle after this loader is gone. Orphan the records: the host keeps them (with
        // the loader field cleared, which the handlers check) until each handler runs or the
        // host is destroyed.
        for (self.pendings.items) |pending| {
            pending.loader = null;
            self.host.orphaned_loads.append(alloc, pending) catch binding.oom();
        }
        self.pendings.deinit(alloc);
        alloc.free(self.js);
        for (self.exts) |ext| alloc.free(ext);
        alloc.free(self.exts);
        alloc.free(self.entries);
    }

    /// Frees a settled load, whether its loader is still alive or has been orphaned.
    fn finish(pending: *Pending) void {
        if (pending.loader) |owner| return owner.release(pending);
        const host = pending.host;
        for (host.orphaned_loads.items, 0..) |item, index| {
            if (item != pending) continue;
            _ = host.orphaned_loads.swapRemove(index);
            break;
        }
        host.allocator.free(pending.module_id);
        host.allocator.destroy(pending);
    }

    /// Drops a settled load from `pendings` and frees it.
    fn release(self: *JsLoader, pending: *Pending) void {
        for (self.pendings.items, 0..) |item, index| {
            if (item != pending) continue;
            _ = self.pendings.swapRemove(index);
            break;
        }
        self.host.allocator.free(pending.module_id);
        self.host.allocator.destroy(pending);
    }

    /// The transformers a source read by this loader passes through.
    pub fn registry(self: *const JsLoader) transformer.Registry {
        return .{ .entries = self.entries };
    }

    /// Installs the extension map from `list`, a JS array `[ext, transformer, ext, ...]`
    /// (the glue flattens `{ ".ts": t }` into it). A transformer is either a host transformer
    /// (a function branded by `transform_handle`) or any other function, called as
    /// `(source, id)` in the parent realm. Validates everything first and only then allocates,
    /// so a failure leaves the loader without transformers. Borrows `list` for the call.
    pub fn setTransformers(self: *JsLoader, ctx: v8.Context, isolate: v8.Isolate, list: v8.Object) !void {
        const length = (list.get(ctx, binding.string(isolate, "length")) orelse return error.InvalidInput).u32Value(ctx) orelse return error.InvalidInput;
        if (length % 2 != 0 or length / 2 > max_transformers) return error.InvalidInput;
        const count = length / 2;

        // Pass 1: read and validate every pair into stack storage; nothing is allocated yet.
        var ext_buffers: [max_transformers][max_extension_len]u8 = undefined;
        var parsed: [max_transformers]struct { ext: []const u8, function: v8.Value, host: ?*const transformer.Transformer } = undefined;
        var js_count: usize = 0;
        for (0..count) |pair| {
            const ext_value = list.getIndex(ctx, @intCast(pair * 2)) orelse return error.InvalidInput;
            const function = list.getIndex(ctx, @intCast(pair * 2 + 1)) orelse return error.InvalidInput;
            if (!ext_value.isString() or !function.isFunction()) return error.InvalidInput;
            const text = ext_value.toString(ctx) orelse return error.InvalidInput;
            if (text.lenUtf8(isolate) > max_extension_len) return error.InvalidInput;
            const ext = ext_buffers[pair][0..text.writeUtf8(isolate, &ext_buffers[pair])];
            if (!validExtension(ext)) return error.InvalidInput;
            for (parsed[0..pair]) |earlier| {
                if (std.mem.eql(u8, earlier.ext, ext)) return error.InvalidInput;
            }
            const host_transformer = transform_handle.read(ctx, isolate, function);
            if (host_transformer == null) js_count += 1;
            parsed[pair] = .{ .ext = ext, .function = function, .host = host_transformer };
        }

        // Pass 2: copy into host-allocated storage owned by the loader.
        const alloc = self.host.allocator;
        const entries = alloc.alloc(transformer.Entry, count) catch binding.oom();
        const exts = alloc.alloc([]u8, count) catch binding.oom();
        const js = alloc.alloc(JsTransformer, js_count) catch binding.oom();
        var js_next: usize = 0;
        for (parsed[0..count], 0..) |item, pair| {
            exts[pair] = alloc.dupe(u8, item.ext) catch binding.oom();
            if (item.host) |host_transformer| {
                entries[pair] = .{ .ext = exts[pair], .transformer = host_transformer.* };
            } else {
                js[js_next] = .{ .loader = self, .function = .new(isolate, v8.Function.from_opaque(item.function.data.handle).?) };
                entries[pair] = .{ .ext = exts[pair], .transformer = .{ .data = &js[js_next], .run = runJs } };
                js_next += 1;
            }
        }
        self.entries = entries;
        self.exts = exts;
        self.js = js;
    }

    /// The `Loader` descriptor for `Scope.Options`; borrows self until `Host.destroy`.
    pub fn loader(self: *JsLoader) module_types.Loader {
        return .{ .data = self, .load = load };
    }
};

/// An asynchronous load in flight; freed by `fulfilled` or `rejected`.
pub const Pending = struct {
    host: *Host,
    /// Null once the loader was deinitialised; the record then belongs to `Host.orphaned_loads`.
    loader: ?*JsLoader,
    token: module_types.LoadToken,
    /// Host-allocator copy of the module id (extension matching happens after the await).
    module_id: []u8,
    /// The import asked for a JSON module (`type: "json"`), so the text is wrapped, not transformed.
    json: bool,
};

/// Extensions the transformer map accepts: a dot, then a name, with no path separators, query
/// or fragment characters, NUL, empty segments or trailing dot (so `.ts`, `.d.ts`, `.test.js`).
fn validExtension(ext: []const u8) bool {
    if (ext.len < 2 or ext[0] != '.' or ext[ext.len - 1] == '.') return false;
    if (std.mem.indexOfAny(u8, ext, "/\\?#\x00") != null) return false;
    return std.mem.indexOf(u8, ext, "..") == null;
}

/// `Transformer.run` for a guest function: calls it in the parent realm, synchronously,
/// with `host.in_loader` set (it may not create scopes), and copies the result out. A throw,
/// a promise or a result of the wrong shape becomes diagnostics. Output is allocated from
/// `request.allocator`.
fn runJs(data: ?*anyopaque, request: transformer.Request) anyerror!transformer.Outcome {
    const self: *JsTransformer = @ptrCast(@alignCast(data.?));
    const host = self.loader.host;
    const isolate = self.loader.parent.runtime.isolate;
    const parent_ctx = self.loader.parent.context.deref();
    parent_ctx.enter();
    defer parent_ctx.exit();
    var h_scope: v8.HandleScope = undefined;
    h_scope.init(isolate);
    defer h_scope.deinit();
    const was_in_loader = host.in_loader;
    host.in_loader = true;
    defer host.in_loader = was_in_loader;
    var tc: v8.TryCatch = undefined;
    tc.init(isolate);
    defer tc.deinit();
    const args = [_]v8.Value{ binding.string(isolate, request.source), binding.string(isolate, request.module_id) };
    const result = self.function.deref().call(parent_ctx, eu.v.undefined_value(isolate).value, &args) orelse {
        const thrown = if (tc.getException()) |exception| exception.toDetailString(parent_ctx) else null;
        const detail = if (thrown) |text| blk: {
            const buffer = try request.allocator.alloc(u8, text.lenUtf8(isolate));
            break :blk buffer[0..text.writeUtf8(isolate, buffer)];
        } else "threw";
        return .{ .diagnostics = try std.fmt.allocPrint(request.allocator, "{s}:1:1: error: transformer failed: {s}", .{ request.module_id, detail }) };
    };
    if (result.isPromise()) {
        return .{ .diagnostics = try std.fmt.allocPrint(request.allocator, "{s}:1:1: error: transformer returned a promise; transformers must be synchronous", .{request.module_id}) };
    }
    const source = sourceOf(parent_ctx, isolate, result, request.allocator) catch {
        return .{ .diagnostics = try std.fmt.allocPrint(request.allocator, "{s}:1:1: error: transformer must return a string or {{ source }}", .{request.module_id}) };
    };
    return .{ .source = source };
}

/// Reads the module source from a loader result: a string, or an object with an
/// own data property `source` that is a string. Copies into `allocator`.
fn sourceOf(ctx: v8.Context, isolate: v8.Isolate, value: v8.Value, allocator: std.mem.Allocator) ![]const u8 {
    var source = value;
    if (!value.isString()) {
        const object = value.toObject(ctx) orelse return error.LoaderFailed;
        const descriptor = object.getOwnPropertyDescriptor(ctx, eu.v.str_utf8(isolate, "source").name) orelse return error.LoaderFailed;
        if (!descriptor.isObject()) return error.LoaderFailed;
        source = (descriptor.toObject(ctx) orelse return error.LoaderFailed).get(ctx, binding.string(isolate, "value")) orelse return error.LoaderFailed;
    }
    if (!source.isString()) return error.LoaderFailed;
    const text = source.toString(ctx) orelse return error.LoaderFailed;
    const buffer = allocator.alloc(u8, text.lenUtf8(isolate)) catch binding.oom();
    return buffer[0..text.writeUtf8(isolate, buffer)];
}

/// What calling the guest loader produced.
const Fetched = union(enum) { pending, source: []const u8 };

fn load(data: ?*anyopaque, request: module_types.LoadRequest) anyerror!module_types.LoadResult {
    const self: *JsLoader = @ptrCast(@alignCast(data.?));
    // The `origine:` namespace is the host's: the scope only reaches this point with it enabled,
    // and the guest loader never gets to serve (or forge) one of its modules.
    if (std.mem.startsWith(u8, request.module_id, module_types.origine_prefix)) {
        for (self.host.modules) |module| {
            if (std.mem.eql(u8, request.module_id, module.id)) return .{ .source = module.source };
        }
        return error.FileNotFound;
    }
    const source = switch (try callLoader(self, request)) {
        .pending => return .pending,
        .source => |text| text,
    };
    if (json_module.requested(request.import_attributes)) return .{ .source = try json_module.wrap(request.allocator, source) };
    // Back in the child's realm: transformer failures become SyntaxErrors of this realm.
    return switch (try self.registry().apply(.{ .allocator = request.allocator, .module_id = request.module_id, .source = source })) {
        .source => |text| .{ .source = text },
        .diagnostics => |text| .{ .exception = transformer.syntaxError(text) },
    };
}

fn callLoader(self: *JsLoader, request: module_types.LoadRequest) anyerror!Fetched {
    const host = self.host;
    const isolate = self.parent.runtime.isolate;
    const parent_ctx = self.parent.context.deref();
    parent_ctx.enter();
    defer parent_ctx.exit();
    // Restore, not clear: a nested loader call must not drop the outer call's guard.
    const was_in_loader = host.in_loader;
    host.in_loader = true;
    defer host.in_loader = was_in_loader;
    var tc: v8.TryCatch = undefined;
    tc.init(isolate);
    defer tc.deinit();
    // The guest sees the import attributes as a plain object: `loader(id, { type: "json" })`.
    const attributes = v8.Object.init(isolate);
    for (request.import_attributes) |attribute| {
        _ = attributes.createDataProperty(parent_ctx, eu.v.str_utf8(isolate, attribute.key).name, binding.string(isolate, attribute.value)) orelse return error.LoaderFailed;
    }
    const result = self.function.deref().call(parent_ctx, eu.v.undefined_value(isolate).value, &.{ binding.string(isolate, request.module_id), attributes.value }) orelse return error.LoaderFailed;
    if (result.isPromise()) {
        const pending = host.allocator.create(Pending) catch binding.oom();
        const module_id = host.allocator.dupe(u8, request.module_id) catch binding.oom();
        pending.* = .{ .host = host, .loader = self, .token = request.token, .module_id = module_id, .json = json_module.requested(request.import_attributes) };
        self.pendings.append(host.allocator, pending) catch binding.oom();
        const external = eu.v.external(isolate, pending).value.data;
        const on_fulfilled = v8.Function.init(parent_ctx, fulfilled, external, 1, .Throw, .HasSideEffect);
        const on_rejected = v8.Function.init(parent_ctx, rejected, external, 1, .Throw, .HasSideEffect);
        const promise = v8.Promise.from_opaque(result.data.handle).?;
        _ = promise.then2(parent_ctx, on_fulfilled, on_rejected) orelse {
            self.release(pending);
            return error.LoaderFailed;
        };
        return .pending;
    }
    return .{ .source = try sourceOf(parent_ctx, isolate, result, request.allocator) };
}

fn fulfilled(info: v8.FunctionCallbackInfo) callconv(.c) void {
    const pending = binding.externalPointer(Pending, info);
    const host = pending.host;
    defer JsLoader.finish(pending);
    const owner = pending.loader orelse return; // the scope this load was for is gone
    const isolate = info.isolate();
    const ctx = isolate.getCurrentContext();
    const rt: *Runtime = runtimeOf(ctx) orelse return;
    const source = sourceOf(ctx, isolate, info.get_arg(0), host.allocator) catch {
        rt.completeLoad(pending.token, .{ .failure = error.LoaderFailed }) catch {};
        return;
    };
    defer host.allocator.free(source);
    if (pending.json) {
        const wrapped = json_module.wrap(host.allocator, source) catch {
            rt.completeLoad(pending.token, .{ .failure = error.LoaderFailed }) catch {};
            return;
        };
        defer host.allocator.free(wrapped);
        rt.completeLoad(pending.token, .{ .content = .{ .source = wrapped } }) catch {};
        return;
    }
    const outcome = owner.registry().apply(.{ .allocator = host.allocator, .module_id = pending.module_id, .source = source }) catch {
        rt.completeLoad(pending.token, .{ .failure = error.LoaderFailed }) catch {};
        return;
    };
    switch (outcome) {
        .source => |text| {
            // `apply` returns the input itself when no transformer matched: freed once, above.
            defer if (text.ptr != source.ptr) host.allocator.free(text);
            rt.completeLoad(pending.token, .{ .content = .{ .source = text } }) catch {};
        },
        .diagnostics => |text| {
            defer host.allocator.free(text);
            rt.completeLoad(pending.token, .{ .syntax_error = text }) catch {};
        },
    }
}

fn rejected(info: v8.FunctionCallbackInfo) callconv(.c) void {
    const pending = binding.externalPointer(Pending, info);
    defer JsLoader.finish(pending);
    if (pending.loader == null) return;
    const ctx = info.isolate().getCurrentContext();
    const rt: *Runtime = runtimeOf(ctx) orelse return;
    rt.completeLoad(pending.token, .{ .failure = error.LoaderRejected }) catch {};
}

/// Finds the Runtime owning `ctx` via the scope pointer in embedder data slot 1.
fn runtimeOf(ctx: v8.Context) ?*Runtime {
    const scope: *Scope = @ptrCast(@alignCast(ctx.getAlignedPointerFromEmbedderData(1) orelse return null));
    return scope.runtime;
}
