//! origine entry point: evaluate a JavaScript file or start a managed REPL.
const std = @import("std");
const v8 = @import("@v8");
const m = @import("@managed");
const eu = @import("@util");
const StartupTrace = @import("@diagnostics").StartupTrace;
const Engine = @import("@engine").Engine;
const build_options = @import("build_options");
var io_runtime: std.Io.Threaded = undefined;

// The Rust library calls the `oio_*` C ABI of the I/O library; keep its exports.
comptime {
    _ = @import("@io").c_api;
}

/// Borrows format/arguments through buffered output; retains no resources.
/// The global host I/O runtime must remain live through return, including I/O errors.
fn print(comptime format: []const u8, args: anytype) void {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io_runtime.io(), &buffer);
    writer.interface.print(format, args) catch return;
    writer.interface.flush() catch return;
}

/// Borrows scope/value through string conversion; caller keeps the runtime alive.
/// Local V8 handles and UTF-8 storage are released before return.
fn show(scope: *m.Scope, value: v8.Global.Of(v8.Value)) void {
    const alloc = eu.alloc;
    const isolate = scope.runtime.isolate;
    isolate.enter();
    defer isolate.exit();
    var h_scope: v8.HandleScope = undefined;
    h_scope.init(isolate);
    defer h_scope.deinit();
    const ctx = scope.context.deref();
    ctx.enter();
    defer ctx.exit();
    // toString may invoke arbitrary guest code, including a throwing getter.
    var tc_scope: v8.TryCatch = undefined;
    tc_scope.init(isolate);
    defer tc_scope.deinit();
    // An Error's stack starts with "Name: message" and adds the frames; diagnostics from the
    // TypeScript transformer put their file:line:col lines there.
    var shown = value.deref();
    if (shown.toObject(ctx)) |object| {
        if (object.get(ctx, eu.v.str_utf8(isolate, "stack").name.primitive.value)) |stack| {
            if (stack.isString()) shown = stack;
        }
    }
    const text = shown.toString(ctx) orelse {
        print("<value conversion threw>\n", .{});
        return;
    };
    const buffer = alloc.alloc(u8, text.lenUtf8(isolate)) catch return;
    defer alloc.free(buffer);
    const length = text.writeUtf8(isolate, buffer);
    print("{s}\n", .{buffer[0..length]});
}

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
    print("JavaScript REPL: exit() or Ctrl+D exits.\n", .{});
    var input_buffer: [8192]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io_runtime.io(), &input_buffer);
    while (true) {
        print("> ", .{});
        const line = (reader.interface.takeDelimiter('\n') catch |err| {
            print("Input error: {s}\n", .{@errorName(err)});
            return;
        }) orelse break;
        const input = std.mem.trim(u8, line, " \r\t");
        if (std.mem.eql(u8, input, "exit()")) break;
        var error_info: m.ErrorInfo = .{};
        defer error_info.deinit();
        const result = scope.eval(input, "app:/shell.js", &error_info) catch |err| {
            print("Evaluation failed: {s}\n", .{@errorName(err)});
            if (error_info.exception) |value| show(scope, value);
            continue;
        };
        defer result.deinit();
        show(scope, result);
        rt.pumpPlatform(engine.platform);
    }
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
    var code_cache = m.Api.init_cache.CodeCacheState.init(io_runtime.io(), host, std.Io.Dir.cwd());
    defer {
        host.destroy();
        if (rt) |runtime| runtime.destroy();
        if (image) |*cached| cached.deinit();
    }
    // The callbacks that may live in a snapshot's heap: the same table must be given to the
    // isolate that makes it and to the one that restores it.
    const references = try host.externalReferences(alloc);
    defer alloc.free(references);
    if (caching) image = initSnapshot(alloc, init.environ_map, host, references, args[1], engine_snapshot);
    trace.mark("init_snapshot");
    rt = try m.Runtime.create(alloc, .{
        .array_buffer_allocator = buffer_allocator,
        .snapshot = if (image) |*cached| cached.blob else engine_snapshot,
        .external_references = m.init_snapshot.referenceTable(references),
    });
    trace.mark("runtime_isolate");
    trace.report();
    var options = host.initOptions();
    if (image) |*cached| options.init_snapshot = &cached.table;
    if (caching) options.code_cache = code_cache.hook();
    const scope = try rt.?.createScope(options);
    var error_info: m.ErrorInfo = .{};
    defer error_info.deinit();
    host.run(scope, engine.platform, args[1], &error_info) catch |err| {
        print("{s}\n", .{@errorName(err)});
        if (error_info.exception) |value| show(scope, value);
        return err;
    };
    // Modules that compiled without a V8 code cache (not in the snapshot) get one now that
    // their code has run, so lazily compiled functions are in it.
    if (caching) _ = scope.flushCodeCache();
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
) ?m.init_snapshot.Image {
    const verbose = environ.get("ORIGINE_SNAPSHOT_LOG") != null;
    const io = io_runtime.io();
    var entry = m.Api.init_cache.entryFor(alloc, io, host, specifier) catch return null;
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
