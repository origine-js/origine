//! origine entry point: evaluate a JavaScript file or start a managed REPL.
const std = @import("std");
const v8 = @import("@v8");
const m = @import("@managed");
const eu = @import("@util");
const StartupTrace = @import("@diagnostics").StartupTrace;
const Engine = @import("@engine").Engine;
const build_options = @import("build_options");
const repl = @import("repl.zig");
var io_runtime: std.Io.Threaded = undefined;

/// Owns the demo engine/runtime and host allocations until exit; releases all V8
/// values before teardown. Uses process-lifetime eu.alloc for host allocations and
/// ArrayBuffer backing stores; frees host storage on success/error without allocator teardown.
/// Owns one V8 background worker until platform teardown; foreground jobs are
/// pumped on the calling thread. No callback state escapes runtime teardown.
pub fn main(init: std.process.Init) !void {
    var trace: StartupTrace = .init();
    const alloc = eu.alloc;
    const args = try init.minimal.args.toSlice(alloc);
    defer alloc.free(args);
    io_runtime = .init(alloc, .{});
    defer io_runtime.deinit();
    trace.mark("host_io");
    var engine = Engine.init(.{ .trace = &trace });
    defer engine.deinit();
    const snapshot = embeddedSnapshot(init.environ_map);
    // The V8 sandbox only accepts its own ArrayBuffer memory, so Zig-allocated backing stores
    // are limited to builds without it.
    const buffer_allocator: @FieldType(m.Runtime.Options, "array_buffer_allocator") =
        if (v8.V8.isSandboxEnabled()) .default else .{ .zig = alloc };
    if (args.len > 1) return runInit(alloc, init, engine, args, &trace, buffer_allocator, snapshot);
    const rt = try m.Runtime.create(alloc, .{ .array_buffer_allocator = buffer_allocator, .snapshot = snapshot });
    trace.mark("runtime_isolate");
    defer rt.destroy();
    const scope = try rt.createScope(.{});
    trace.mark("scope_create");
    trace.report();
    @import("@diagnostics").scope.report();
    const interactive = repl.isInteractive(io_runtime.io(), init.environ_map);
    if (interactive) repl.display.print(io_runtime.io(), "JavaScript REPL: .help for commands; exit() or Ctrl+D exits.\n", .{});
    try repl.run(scope, .{
        .allocator = alloc,
        .io = io_runtime.io(),
        .platform = engine.platform,
        .interactive = interactive,
        .colors = interactive and init.environ_map.get("NO_COLOR") == null,
    });
}

/// Runs `args[1]` as the init module: evaluates it, then calls its exported
/// `main(api)` with every permission granted (the CLI grants the working directory
/// read/write with sync and async access (async runtimes through `api.io`), all arguments after the init path, and the whole
/// environment). The evaluated init graph is cached as a snapshot in `__oricache__` next to
/// the init file: the first run creates it, later runs restore it instead of evaluating the
/// init again. Borrows everything through return.
fn runInit(
    alloc: std.mem.Allocator,
    init: std.process.Init,
    engine: Engine,
    args: []const [:0]const u8,
    trace: *StartupTrace,
    buffer_allocator: @FieldType(m.Runtime.Options, "array_buffer_allocator"),
    engine_snapshot: ?[]align(16) const u8,
) !void {
    const user_args = try alloc.alloc([]const u8, args.len - 1);
    defer alloc.free(user_args);
    for (args[1..], user_args) |arg, *out| out.* = arg;
    const keys = init.environ_map.keys();
    const values = init.environ_map.values();
    const env = try alloc.alloc(m.Api.EnvPair, keys.len);
    defer alloc.free(env);
    for (keys, values, env) |key, value, *out| out.* = .{ .name = key, .value = value };
    var cwd = try std.Io.Dir.cwd().openDir(io_runtime.io(), ".", .{ .iterate = true });
    defer cwd.close(io_runtime.io());
    const host = try m.Api.Host.create(alloc, .{ .io = io_runtime.io(), .args = user_args, .env = env, .fs = .{ .root = cwd }, .runtime = .{} });
    // The host releases V8 handles, so it goes before the runtime; the snapshot image backs
    // the runtime's heap, so it goes after.
    var image: ?m.init_snapshot.Image = null;
    var rt: ?*m.Runtime = null;
    const caching = init.environ_map.get("ORIGINE_NO_SNAPSHOT") == null;
    const engine_key = m.Api.init_cache.engineKey(io_runtime.io(), host);
    var code_cache = m.Api.init_cache.CodeCacheState.initWithKey(engine_key, host, std.Io.Dir.cwd());
    defer {
        host.destroy();
        if (rt) |runtime| runtime.destroy();
        if (image) |*cached| cached.deinit();
    }
    // The callbacks that may live in a snapshot's heap: the same table must be given to the
    // isolate that makes it and to the one that restores it.
    const references = try host.externalReferences(alloc);
    defer alloc.free(references);
    if (caching) image = initSnapshot(alloc, init.environ_map, host, references, args[1], engine_snapshot, engine_key);
    trace.mark("init_snapshot");
    rt = try m.Runtime.create(alloc, .{
        .array_buffer_allocator = buffer_allocator,
        .snapshot = if (image) |*cached| cached.blob else engine_snapshot,
        .external_references = m.init_snapshot.referenceTable(references),
    });
    trace.mark("runtime_isolate");
    var options = host.initOptions();
    if (image) |*cached| options.init_snapshot = &cached.table;
    if (caching) options.code_cache = code_cache.hook();
    const scope = try rt.?.createScope(options);
    trace.mark("create_scope");
    var error_info: m.ErrorInfo = .{};
    defer error_info.deinit();
    host.run(scope, engine.platform, args[1], &error_info) catch |err| {
        repl.display.print(io_runtime.io(), "{s}\n", .{@errorName(err)});
        if (error_info.exception) |value| repl.display.show(io_runtime.io(), scope, value);
        return err;
    };
    trace.mark("host_run");
    defer {
        trace.report();
        @import("@diagnostics").scope.report();
    }
    // Modules that compiled without a V8 code cache (not in the snapshot) get one now that
    // their code has run, so lazily compiled functions are in it.
    if (caching) {
        _ = scope.flushCodeCache();
        host.flushGlueCache(scope);
    }
}

/// The cached snapshot of the init graph at `specifier`, created and stored on a miss. Null
/// means "run without": no cache directory, an init that cannot be snapshotted (it throws,
/// waits on I/O or imports a host module) or any other failure; the normal path then reports
/// whatever is wrong with the init. With ORIGINE_SNAPSHOT_LOG set, says why on stderr.
/// Borrows everything through return.
fn initSnapshot(
    alloc: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    host: *m.Api.Host,
    references: []const ?*const anyopaque,
    specifier: []const u8,
    engine_snapshot: ?[]align(16) const u8,
    engine_key: m.Api.init_cache.Hash,
) ?m.init_snapshot.Image {
    const verbose = environ.get("ORIGINE_SNAPSHOT_LOG") != null;
    const io = io_runtime.io();
    var entry = m.Api.init_cache.entryWithKey(alloc, engine_key, specifier) catch return null;
    defer entry.deinit();
    var miss: m.Api.init_cache.Miss = undefined;
    if (m.Api.init_cache.load(alloc, io, std.Io.Dir.cwd(), &entry, m.Api.init_cache.sourceHasher(host), &miss)) |hit| {
        if (verbose) std.debug.print("init snapshot: reused {s}\n", .{entry.path});
        return hit;
    }
    if (verbose) std.debug.print("init snapshot: cache miss ({s})\n", .{@tagName(miss)});
    var label: [128]u8 = undefined;
    const options = host.initOptions();
    const created = m.init_snapshot.create(alloc, .{
        .key = entry.key,
        .identity = m.Api.init_cache.identity(&label),
        .scope = options,
        .specifier = specifier,
        .source_hasher = m.Api.init_cache.sourceHasher(host),
        .hooks = host.snapshotHooks(),
        .external_references = m.init_snapshot.referenceTable(references),
        .base_snapshot = engine_snapshot,
    }) catch |err| {
        if (verbose) std.debug.print("init snapshot: not created ({s})\n", .{@errorName(err)});
        return null;
    };
    m.Api.init_cache.store(alloc, io, std.Io.Dir.cwd(), &entry, &created) catch |err| {
        if (verbose) std.debug.print("init snapshot: not stored ({s})\n", .{@errorName(err)});
        return created;
    };
    if (verbose) std.debug.print("init snapshot: created {s}\n", .{entry.path});
    return created;
}

/// The frozen-intrinsics startup snapshot generated at build time (see build.zig and
/// snapshot_tool.zig). `align(16)` as V8 requires; empty when the build could not
/// generate one (cross builds).
const embedded_snapshot: [if (build_options.has_snapshot) @embedFile("engine_snapshot").len else 0]u8 align(16) =
    if (build_options.has_snapshot) @embedFile("engine_snapshot").* else .{};

/// Returns the embedded snapshot, or null to use V8's built-in seed (no embedded
/// blob, or ORIGINE_NO_SNAPSHOT is set for comparison runs).
fn embeddedSnapshot(environ: *const std.process.Environ.Map) ?[]align(16) const u8 {
    if (embedded_snapshot.len == 0 or environ.get("ORIGINE_NO_SNAPSHOT") != null) return null;
    return &embedded_snapshot;
}
