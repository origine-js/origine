//! origine entry point: evaluate a JavaScript file or start a managed REPL.
const std = @import("std");
const v8 = @import("@v8");
const m = @import("@managed");
const eu = @import("@util");
const StartupTrace = @import("@diagnostics").StartupTrace;
const Engine = @import("@engine").Engine;
const build_options = @import("build_options");
const repl = @import("repl.zig");

pub const panic = std.debug.FullPanic(libcPanic);

/// Reports the message on stderr and aborts, like the default handler minus the stack-trace
/// symbolizer (which needs `std.Options.debug_io`, a global `Io.Threaded`, and finds no debug info
/// in a stripped release binary anyway).
fn libcPanic(msg: []const u8, _: ?usize) noreturn {
    _ = std.c.write(2, msg.ptr, msg.len);
    _ = std.c.write(2, "\n", 1);
    std.c.abort();
}

/// No per-thread alternate signal stack: nothing installs a segfault handler, and the default
/// reserves 256 KiB of thread-local storage in every object that links `std.Thread`.
pub const std_options: std.Options = .{ .signal_stack_size = null };

/// `std.debug` and `std.log` write through this; the default is a global `Io.Threaded`, the whole
/// thread pool and every file, socket and process operation, for a few lines of stderr text. Nothing
/// here prints through std (see `managed/stderr.zig`), so a stray use fails instead of linking it.
pub const std_options_debug_io: std.Io = std.Io.failing;

/// Owns the demo engine/runtime and host allocations until exit; releases all V8
/// values before teardown. Uses process-lifetime eu.alloc for host allocations and
/// ArrayBuffer backing stores; frees host storage on success/error without allocator teardown.
/// Owns one V8 background worker until platform teardown; foreground jobs are
/// pumped on the calling thread. No callback state escapes runtime teardown.
pub fn main(init: std.process.Init.Minimal) !void {
    var trace: StartupTrace = .init();
    const alloc = eu.alloc;
    const args = try init.args.toSlice(alloc);
    defer alloc.free(args);
    var environ_map = try init.environ.createMap(alloc);
    defer environ_map.deinit();
    const environ = &environ_map;
    var engine = Engine.init(.{ .trace = &trace });
    defer engine.deinit();
    const snapshot = embeddedSnapshot(environ);
    // The V8 sandbox only accepts ArrayBuffer memory inside itself, so a sandboxed V8 gets
    // backing stores from its own pages; builds without it use the Zig allocator.
    const buffer_allocator: @FieldType(m.Runtime.Options, "array_buffer_allocator") =
        if (v8.V8.isSandboxEnabled()) .sandbox else .{ .zig = alloc };
    if (args.len > 1) return runInit(alloc, environ, engine, args, &trace, buffer_allocator, snapshot);
    return runRepl(alloc, environ, engine, &trace, buffer_allocator, snapshot);
}

/// Builds the host every entry point runs with: the working directory read/write with sync and
/// async access, all `user_args`, and the whole environment. `env` is caller-owned storage.
fn createHost(alloc: std.mem.Allocator, environ: *const std.process.Environ.Map, user_args: []const []const u8, env: []m.Api.EnvPair, cwd: m.sys.Dir) !*m.Api.Host {
    const keys = environ.keys();
    const values = environ.values();
    for (keys, values, env) |key, value, *out| out.* = .{ .name = key, .value = value };
    return m.Api.Host.create(alloc, .{ .args = user_args, .env = env, .fs = .{ .root = cwd }, .runtime = .{} });
}

/// Starts the REPL with the same host API as an init module: `api` is a global and `import`
/// resolves `origine:@std/*` and files under the working directory. Borrows everything through return.
fn runRepl(
    alloc: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    engine: Engine,
    trace: *StartupTrace,
    buffer_allocator: @FieldType(m.Runtime.Options, "array_buffer_allocator"),
    engine_snapshot: ?[]align(16) const u8,
) !void {
    const env = try alloc.alloc(m.Api.EnvPair, environ.keys().len);
    defer alloc.free(env);
    var cwd = try m.sys.Dir.cwd().openDir(".", .{ .iterate = true });
    defer cwd.close();
    const host = try createHost(alloc, environ, &.{}, env, cwd);
    var rt: ?*m.Runtime = null;
    // The host releases V8 handles, so it goes before the runtime.
    defer {
        host.destroy();
        if (rt) |runtime| runtime.destroy();
    }
    const references = try host.externalReferences(alloc);
    defer alloc.free(references);
    rt = try m.Runtime.create(alloc, .{
        .array_buffer_allocator = buffer_allocator,
        .snapshot = engine_snapshot,
        .external_references = m.init_snapshot.referenceTable(references),
    });
    trace.mark("runtime_isolate");
    const scope = try rt.?.createScope(host.initOptions());
    trace.mark("scope_create");
    trace.report();
    @import("@diagnostics").scope.report();
    const interactive = repl.isInteractive(environ);
    if (interactive) repl.display.print("JavaScript REPL: .help for commands; exit() or Ctrl+D exits.\n", .{});
    try repl.run(scope, .{
        .allocator = alloc,
        .platform = engine.platform,
        .interactive = interactive,
        .colors = interactive and environ.get("NO_COLOR") == null,
        .host = host,
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
    environ: *const std.process.Environ.Map,
    engine: Engine,
    args: []const [:0]const u8,
    trace: *StartupTrace,
    buffer_allocator: @FieldType(m.Runtime.Options, "array_buffer_allocator"),
    engine_snapshot: ?[]align(16) const u8,
) !void {
    const user_args = try alloc.alloc([]const u8, args.len - 1);
    defer alloc.free(user_args);
    for (args[1..], user_args) |arg, *out| out.* = arg;
    const env = try alloc.alloc(m.Api.EnvPair, environ.keys().len);
    defer alloc.free(env);
    var cwd = try m.sys.Dir.cwd().openDir(".", .{ .iterate = true });
    defer cwd.close();
    const host = try createHost(alloc, environ, user_args, env, cwd);
    // The host releases V8 handles, so it goes before the runtime; the snapshot image backs
    // the runtime's heap, so it goes after.
    var image: ?m.init_snapshot.Image = null;
    var rt: ?*m.Runtime = null;
    const caching = environ.get("ORIGINE_NO_SNAPSHOT") == null;
    const engine_key = m.Api.init_cache.engineKey(host);
    var code_cache = m.Api.init_cache.CodeCacheState.initWithKey(engine_key, host, m.sys.Dir.cwd());
    defer {
        host.destroy();
        if (rt) |runtime| runtime.destroy();
        if (image) |*cached| cached.deinit();
    }
    // The callbacks that may live in a snapshot's heap: the same table must be given to the
    // isolate that makes it and to the one that restores it.
    const references = try host.externalReferences(alloc);
    defer alloc.free(references);
    if (caching) image = initSnapshot(alloc, environ, host, references, args[1], engine_snapshot, engine_key);
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
        repl.display.print("{s}\n", .{@errorName(err)});
        if (error_info.exception) |value| repl.display.show(scope, value);
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
    var entry = m.Api.init_cache.entryWithKey(alloc, engine_key, specifier) catch return null;
    defer entry.deinit();
    var miss: m.Api.init_cache.Miss = undefined;
    if (m.Api.init_cache.load(alloc, m.sys.Dir.cwd(), &entry, m.Api.init_cache.sourceHasher(host), &miss)) |hit| {
        if (verbose) m.stderr.print("init snapshot: reused {s}\n", .{entry.path});
        return hit;
    }
    if (verbose) m.stderr.print("init snapshot: cache miss ({s})\n", .{@tagName(miss)});
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
        if (verbose) m.stderr.print("init snapshot: not created ({s})\n", .{@errorName(err)});
        return null;
    };
    m.Api.init_cache.store(alloc, m.sys.Dir.cwd(), &entry, &created) catch |err| {
        if (verbose) m.stderr.print("init snapshot: not stored ({s})\n", .{@errorName(err)});
        return created;
    };
    if (verbose) m.stderr.print("init snapshot: created {s}\n", .{entry.path});
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
