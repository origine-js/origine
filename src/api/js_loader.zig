//! A module `Loader` backed by a JS callback: `loader(moduleId) => source | { source }`
//! (or a promise of either). The callback runs in the creating scope's realm; its
//! result is copied into the child as module source, after the child's extension-keyed
//! transformers (api.scope.create `transformers`) have run on it.
const std = @import("std");
const v8 = @import("@v8");
const binding = @import("binding.zig");
const Runtime = @import("../managed/runtime.zig").Runtime;
const Scope = @import("../managed/scope.zig").Scope;
const module_types = @import("../managed/module_types.zig");
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

pub const JsLoader = struct {
    host: *Host,
    parent: *Scope,
    function: v8.Global.Of(v8.Function),
    /// This child's extension map. `entries[i].ext` is `exts[i]`; JS entries point into `js`.
    /// All host-allocator storage owned by the loader; set once by `setTransformers`.
    entries: []transformer.Entry = &.{},
    exts: [][]u8 = &.{},
    js: []JsTransformer = &.{},

    /// Releases the loader function, the transformer functions and all storage. Call once,
    /// before `Runtime.destroy`.
    pub fn deinit(self: *JsLoader) void {
        const alloc = self.host.allocator;
        self.function.deinit();
        for (self.js) |*entry| entry.function.deinit();
        alloc.free(self.js);
        for (self.exts) |ext| alloc.free(ext);
        alloc.free(self.exts);
        alloc.free(self.entries);
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
        const length = (list.get(ctx, binding.string(isolate, "length")) orelse return error.InvalidPath).u32Value(ctx) orelse return error.InvalidPath;
        if (length % 2 != 0 or length / 2 > max_transformers) return error.InvalidPath;
        const count = length / 2;
        var js_count: usize = 0;
        for (0..count) |pair| {
            const ext_value = list.getIndex(ctx, @intCast(pair * 2)) orelse return error.InvalidPath;
            const function = list.getIndex(ctx, @intCast(pair * 2 + 1)) orelse return error.InvalidPath;
            if (!ext_value.isString() or !function.isFunction()) return error.InvalidPath;
            var buffer: [64]u8 = undefined;
            const text = ext_value.toString(ctx) orelse return error.InvalidPath;
            if (text.lenUtf8(isolate) > buffer.len) return error.InvalidPath;
            const ext = buffer[0..text.writeUtf8(isolate, &buffer)];
            if (!validExtension(ext)) return error.InvalidPath;
            for (0..pair) |earlier| {
                const other = list.getIndex(ctx, @intCast(earlier * 2)) orelse return error.InvalidPath;
                var other_buffer: [64]u8 = undefined;
                const other_text = other.toString(ctx) orelse return error.InvalidPath;
                if (other_text.lenUtf8(isolate) <= other_buffer.len and std.mem.eql(u8, ext, other_buffer[0..other_text.writeUtf8(isolate, &other_buffer)])) return error.InvalidPath;
            }
            if (transform_handle.read(ctx, isolate, function) == null) js_count += 1;
        }
        const alloc = self.host.allocator;
        const entries = alloc.alloc(transformer.Entry, count) catch binding.oom();
        const exts = alloc.alloc([]u8, count) catch binding.oom();
        const js = alloc.alloc(JsTransformer, js_count) catch binding.oom();
        var js_next: usize = 0;
        for (0..count) |pair| {
            const ext_value = list.getIndex(ctx, @intCast(pair * 2)).?;
            const function = list.getIndex(ctx, @intCast(pair * 2 + 1)).?;
            const text = ext_value.toString(ctx).?;
            const owned = alloc.alloc(u8, text.lenUtf8(isolate)) catch binding.oom();
            _ = text.writeUtf8(isolate, owned);
            exts[pair] = owned;
            if (transform_handle.read(ctx, isolate, function)) |host_transformer| {
                entries[pair] = .{ .ext = owned, .transformer = host_transformer.* };
            } else {
                js[js_next] = .{ .loader = self, .function = .new(isolate, v8.Function.from_opaque(function.data.handle).?) };
                entries[pair] = .{ .ext = owned, .transformer = .{ .data = &js[js_next], .run = runJs } };
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
const Pending = struct {
    host: *Host,
    loader: *JsLoader,
    token: module_types.LoadToken,
    /// Host-allocator copy of the module id (extension matching happens after the await).
    module_id: []u8,
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
    const result = self.function.deref().call(parent_ctx, v8.Primitive.initUndefined(isolate).value, &args) orelse {
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
        const descriptor = object.getOwnPropertyDescriptor(ctx, v8.String.initUtf8(isolate, "source").name) orelse return error.LoaderFailed;
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
    const source = switch (try callLoader(self, request)) {
        .pending => return .pending,
        .source => |text| text,
    };
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
    host.in_loader = true;
    defer host.in_loader = false;
    var tc: v8.TryCatch = undefined;
    tc.init(isolate);
    defer tc.deinit();
    const result = self.function.deref().call(parent_ctx, v8.Primitive.initUndefined(isolate).value, &.{binding.string(isolate, request.module_id)}) orelse return error.LoaderFailed;
    if (result.isPromise()) {
        const pending = host.allocator.create(Pending) catch binding.oom();
        const module_id = host.allocator.dupe(u8, request.module_id) catch binding.oom();
        pending.* = .{ .host = host, .loader = self, .token = request.token, .module_id = module_id };
        const external = v8.External.init(isolate, pending).value.data;
        const on_fulfilled = v8.Function.init(parent_ctx, fulfilled, external, 1, .Throw, .HasSideEffect);
        const on_rejected = v8.Function.init(parent_ctx, rejected, external, 1, .Throw, .HasSideEffect);
        const promise = v8.Promise.from_opaque(result.data.handle).?;
        _ = promise.then2(parent_ctx, on_fulfilled, on_rejected) orelse return error.LoaderFailed;
        return .pending;
    }
    return .{ .source = try sourceOf(parent_ctx, isolate, result, request.allocator) };
}

fn fulfilled(info: v8.FunctionCallbackInfo) callconv(.c) void {
    const pending = binding.externalPointer(Pending, info);
    const host = pending.host;
    defer {
        host.allocator.free(pending.module_id);
        host.allocator.destroy(pending);
    }
    const isolate = info.isolate();
    const ctx = isolate.getCurrentContext();
    const rt: *Runtime = runtimeOf(ctx) orelse return;
    const source = sourceOf(ctx, isolate, info.get_arg(0), host.allocator) catch {
        rt.completeLoad(pending.token, .{ .failure = error.LoaderFailed }) catch {};
        return;
    };
    defer host.allocator.free(source);
    const outcome = pending.loader.registry().apply(.{ .allocator = host.allocator, .module_id = pending.module_id, .source = source }) catch {
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
    defer {
        pending.host.allocator.free(pending.module_id);
        pending.host.allocator.destroy(pending);
    }
    const ctx = info.isolate().getCurrentContext();
    const rt: *Runtime = runtimeOf(ctx) orelse return;
    rt.completeLoad(pending.token, .{ .failure = error.LoaderRejected }) catch {};
}

/// Finds the Runtime owning `ctx` via the scope pointer in embedder data slot 1.
fn runtimeOf(ctx: v8.Context) ?*Runtime {
    const scope: *Scope = @ptrCast(@alignCast(ctx.getAlignedPointerFromEmbedderData(1) orelse return null));
    return scope.runtime;
}
