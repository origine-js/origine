//! Source transformers chosen by file extension. A `Registry` maps extensions (`.ts`, `.tsx`,
//! ...) to a `Transformer`; the loaders run `apply` on every source they read, so a module
//! whose extension has no entry reaches V8 untouched. This file knows nothing about oxc: a
//! transformer is any `run` function (see oxc.zig for the TypeScript/JSX one).
const std = @import("std");
const v8 = @import("@v8");

/// One transform call. Everything is borrowed for the call only.
pub const Request = struct {
    /// Backs `Outcome.source`; the caller decides its lifetime (runtime arena in synchronous
    /// loaders, the host allocator in asynchronous ones, which then frees the result).
    allocator: std.mem.Allocator,
    module_id: []const u8,
    source: []const u8,
};

pub const Outcome = union(enum) {
    /// The transformed source, allocated from `Request.allocator`.
    source: []const u8,
    /// Why the source was rejected (`file:line:col: error: message` lines), allocated from
    /// `Request.allocator`. The loader turns it into a `SyntaxError` in the realm that
    /// imports the module, so no value ever crosses realms.
    diagnostics: []const u8,
};

/// A `SyntaxError` carrying `diagnostics` as both message and stack, so the shell prints the
/// `file:line:col` lines. Needs an entered context and a live HandleScope; returns a local
/// handle in the current context. Borrows `diagnostics` for the call.
pub fn syntaxError(diagnostics: []const u8) v8.Value {
    const isolate = v8.Isolate.getCurrent();
    const ctx = isolate.getCurrentContext();
    const message = v8.String.initUtf8(isolate, std.mem.trimEnd(u8, diagnostics, "\n"));
    const exception = v8.Exception.syntaxError(message).?;
    if (exception.toObject(ctx)) |object| {
        _ = object.createDataProperty(ctx, v8.String.initUtf8(isolate, "stack").name, message.name.primitive.value);
    }
    return exception;
}

pub const Transformer = struct {
    /// Transformer-owned state, borrowed without destruction; must outlive every use.
    data: ?*anyopaque = null,
    /// Runs on the isolate thread. Retains none of the request.
    run: *const fn (data: ?*anyopaque, request: Request) anyerror!Outcome,
};

pub const Entry = struct {
    /// Including the dot, for example ".tsx". Borrowed.
    ext: []const u8,
    transformer: Transformer,
};

pub const Registry = struct {
    /// Borrowed for the registry's lifetime.
    entries: []const Entry = &.{},

    /// The transformer for `module_id`: the entry whose extension is the longest suffix of the
    /// id's path (a trailing `?query` or `#fragment` is ignored, matching is case-sensitive, and
    /// the whole name is never an extension). Null when no entry matches.
    pub fn find(self: Registry, module_id: []const u8) ?Transformer {
        const path = module_id[0 .. std.mem.indexOfAny(u8, module_id, "?#") orelse module_id.len];
        var best: ?Entry = null;
        for (self.entries) |entry| {
            if (path.len <= entry.ext.len or !std.mem.endsWith(u8, path, entry.ext)) continue;
            if (best == null or entry.ext.len > best.?.ext.len) best = entry;
        }
        return if (best) |entry| entry.transformer else null;
    }

    /// Transforms `request.source` if an entry matches, else returns it unchanged (the same
    /// slice, not a copy). Errors are the transformer's.
    pub fn apply(self: Registry, request: Request) anyerror!Outcome {
        const transformer = self.find(request.module_id) orelse return .{ .source = request.source };
        return transformer.run(transformer.data, request);
    }
};
