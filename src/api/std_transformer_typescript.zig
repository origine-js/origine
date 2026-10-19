//! `origine:@std/transformer/typescript`: factories for host transformers (see src/js/std_transformer_typescript.js).
//! Each `make` call creates a native function `(source, id) => string` backed by an `Instance`
//! with its own oxc options, branded (transform_handle.zig) so `api.scope.create` can run it
//! directly. Instances live in the module's per-scope state until `Host.destroy`.
const std = @import("std");
const v8 = @import("@v8");
const binding = @import("binding.zig");
const Call = binding.Call;
const func = binding.func;
const module = @import("module.zig");
const ScopeState = @import("host.zig").ScopeState;
const oxc = @import("oxc.zig");
const transformer = @import("transformer.zig");
const transform_handle = @import("transform_handle.zig");

/// One transformer: the options it was made with (strings owned) and the `Transformer` handle
/// the host runs. Native state of the function `make` returns.
const Instance = struct {
    scope: *ScopeState,
    options: oxc.Options,
    handle: transformer.Transformer,

    // Binding State protocol (see binding.zig).
    pub fn errnoCell(self: *Instance) *u32 {
        return self.scope.errnoCell();
    }
    pub fn allocator(self: *Instance) std.mem.Allocator {
        return self.scope.allocator();
    }

    fn deinit(self: *Instance) void {
        const alloc = self.scope.allocator();
        if (self.options.jsx_import_source) |text| alloc.free(text);
        if (self.options.jsx_pragma) |text| alloc.free(text);
        if (self.options.jsx_pragma_frag) |text| alloc.free(text);
        alloc.destroy(self);
    }

    /// `(source, id) => string`: transforms with this instance's options. On bad input it
    /// throws a SyntaxError carrying the diagnostics and returns undefined. Borrows its
    /// arguments for the call; the result is a new JS string.
    fn call(self: *Instance, c: *Call, source: []const u8, id: []const u8) ?v8.Value {
        const result = oxc.transform(c.arena, id, source, self.options) catch binding.oom();
        switch (result) {
            .ok => |code| return binding.string(c.isolate, code),
            .failure => |diagnostics| {
                _ = c.isolate.throwException(transformer.syntaxError(diagnostics));
                return null;
            },
        }
    }
};

/// Per-scope state of this module: every instance `make` created.
const Factory = struct {
    scope: *ScopeState,
    instances: std.ArrayList(*Instance) = .empty,

    pub fn init(scope: *ScopeState) !Factory {
        return .{ .scope = scope };
    }

    pub fn deinit(self: *Factory) void {
        for (self.instances.items) |instance| instance.deinit();
        self.instances.deinit(self.scope.allocator());
    }
};

/// An own data property of `object`, or null (accessors are never invoked).
fn ownValue(ctx: v8.Context, isolate: v8.Isolate, object: v8.Object, name: []const u8) ?v8.Value {
    const descriptor = object.getOwnPropertyDescriptor(ctx, v8.String.initUtf8(isolate, name).name) orelse return null;
    if (!descriptor.isObject()) return null;
    const value = (descriptor.toObject(ctx) orelse return null).get(ctx, binding.string(isolate, "value")) orelse return null;
    return if (value.isUndefined()) null else value;
}

/// Releases the half-built `instance`, throws a TypeError and returns undefined.
fn badOptions(instance: *Instance, isolate: v8.Isolate, message: []const u8) ?v8.Value {
    instance.deinit();
    _ = isolate.throwException(v8.Exception.typeError(v8.String.initUtf8(isolate, message)).?);
    return null;
}

/// `make(options?)`: a branded transformer function. Options are read as own data properties
/// (`jsx`, `importSource`, `pragma`, `pragmaFrag`, `development`, `verbatimImports`,
/// `inlineSourceMap`); anything of the wrong type throws a TypeError. Needs the scope's
/// context entered, as every native call does.
fn make(cell: *module.Cell(Factory), c: *Call, options: ?v8.Object) !?v8.Value {
    const scope = cell.scope;
    const alloc = scope.allocator();
    const instance = try alloc.create(Instance);
    instance.* = .{ .scope = scope, .options = .{}, .handle = .{ .data = &instance.options, .run = oxc.run } };
    errdefer instance.deinit();
    if (options) |object| {
        if (ownValue(c.ctx, c.isolate, object, "jsx")) |value| {
            if (!value.isString()) return badOptions(instance, c.isolate, "jsx must be 'automatic' or 'classic'");
            var buffer: [16]u8 = undefined;
            const text = value.toString(c.ctx).?;
            const mode = if (text.lenUtf8(c.isolate) <= buffer.len) buffer[0..text.writeUtf8(c.isolate, &buffer)] else "";
            if (std.mem.eql(u8, mode, "automatic")) {
                instance.options.jsx_runtime = .automatic;
            } else if (std.mem.eql(u8, mode, "classic")) {
                instance.options.jsx_runtime = .classic;
            } else return badOptions(instance, c.isolate, "jsx must be 'automatic' or 'classic'");
        }
        const strings = [_]struct { name: []const u8, field: *?[]const u8 }{
            .{ .name = "importSource", .field = &instance.options.jsx_import_source },
            .{ .name = "pragma", .field = &instance.options.jsx_pragma },
            .{ .name = "pragmaFrag", .field = &instance.options.jsx_pragma_frag },
        };
        for (strings) |entry| if (ownValue(c.ctx, c.isolate, object, entry.name)) |value| {
            if (!value.isString()) return badOptions(instance, c.isolate, "importSource, pragma and pragmaFrag must be strings");
            const text = value.toString(c.ctx).?;
            const owned = try alloc.alloc(u8, text.lenUtf8(c.isolate));
            _ = text.writeUtf8(c.isolate, owned);
            entry.field.* = owned;
        };
        const flags = [_]struct { name: []const u8, field: *bool }{
            .{ .name = "development", .field = &instance.options.jsx_development },
            .{ .name = "verbatimImports", .field = &instance.options.verbatim_imports },
            .{ .name = "inlineSourceMap", .field = &instance.options.inline_source_map },
        };
        for (flags) |entry| if (ownValue(c.ctx, c.isolate, object, entry.name)) |value| {
            if (!value.isBoolean()) return badOptions(instance, c.isolate, "development, verbatimImports and inlineSourceMap must be booleans");
            entry.field.* = value.booleanValue(c.isolate);
        };
    }
    try cell.data.instances.append(alloc, instance);
    const data = v8.External.init(c.isolate, instance).value.data;
    const function = v8.Function.init(c.ctx, binding.native(Instance, Instance.call), data, 2, .Throw, .HasNoSideEffect);
    try transform_handle.mark(c.ctx, c.isolate, function, &instance.handle);
    return function.object.value;
}

pub fn modules() [if (oxc.enabled) 1 else 0]module.Module {
    if (!oxc.enabled) return .{};
    return .{.{
        .id = "origine:@std/transformer/typescript",
        .source = @embedFile("../js/std_transformer_typescript.js"),
        .bindings = module.stateful(Factory, .{ .make = func(make, .{ .side_effect = .any }) }),
    }};
}
