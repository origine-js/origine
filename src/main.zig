//! origine entry point: evaluate a JavaScript file or start a managed REPL.
const std = @import("std");
const v8 = @import("@v8");
const m = @import("@managed");
const eu = @import("@util");
const StartupTrace = @import("@diagnostics").StartupTrace;
const Engine = @import("@engine").Engine;
const build_options = @import("build_options");
const repl = @import("repl.zig");
const lz4 = @import("@lz4");

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
/// Runs the program and turns a failure into exit status 1 with `error: <name>` on stderr. Returning the error from
/// `main` would make std's start code print it through `std_options_debug_io`, which is `Io.failing` (see above): a panic.
pub fn main(init: std.process.Init.Minimal) u8 {
    run(init) catch |err| {
        m.stderr.print("error: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn run(init: std.process.Init.Minimal) !void {
    var trace: StartupTrace = .init();
    const alloc = eu.alloc;
    const args = try init.args.toSlice(alloc);
    defer alloc.free(args);
    var environ_map = try init.environ.createMap(alloc);
    defer environ_map.deinit();
    const environ = &environ_map;
    var engine = Engine.init(.{ .trace = &trace, .thread_pool_size = v8Workers(environ) });
    defer engine.deinit();
    const snapshot = embeddedSnapshot(alloc);
    // One backing-store allocator for the whole process, shared by the init snapshot and the
    // runtime. The V8 sandbox only accepts ArrayBuffer memory inside itself, so a sandboxed V8
    // gets it from its own pages; builds without it use the Zig allocator. Declared after
    // `engine`, so it is released before V8 is disposed.
    const buffer_allocator = if (v8.V8.isSandboxEnabled())
        try v8.ArrayBuffer.Allocator.fromSandbox()
    else
        try v8.ArrayBuffer.Allocator.fromZig(alloc);
    defer buffer_allocator.deinit();
    // Network flags come first; the init path follows them. `args[first - 1]` stands in for the program name.
    var rules: std.ArrayList(u8) = .empty;
    defer rules.deinit(alloc);
    try rules.appendSlice(alloc, m.Api.loopback_rules);
    var first: usize = 1;
    while (first < args.len and try netFlag(alloc, &rules, args[first])) first += 1;
    var detail: [256]u8 = undefined;
    if (m.Api.checkNetRules(rules.items, &detail)) |why| {
        m.stderr.print("error: network rules: {s}\n", .{why});
        return error.InvalidNetRules;
    }
    const net: m.Api.NetConfig = .{ .rules = rules.items };
    if (args.len > first) return runInit(alloc, environ, engine, args[first - 1 ..], net, &trace, buffer_allocator, snapshot);
    return runRepl(alloc, environ, engine, net, &trace, buffer_allocator, snapshot);
}

/// `--net-connect=<cidr>[@ports]` and `--net-listen=<cidr>[@ports]` add a rule to the loopback default (the
/// grammar is `docs/net-grant.md`); `<cidr>` may be `any` (both families, everywhere). False when `arg` is not
/// a network flag, which is where the init path begins.
fn netFlag(alloc: std.mem.Allocator, rules: *std.ArrayList(u8), arg: []const u8) !bool {
    const kinds = [_]struct { flag: []const u8, rule: []const u8 }{
        .{ .flag = "--net-connect=", .rule = "connect" },
        .{ .flag = "--net-listen=", .rule = "listen" },
    };
    for (kinds) |kind| {
        if (!std.mem.startsWith(u8, arg, kind.flag)) continue;
        const spec = arg[kind.flag.len..];
        const at = std.mem.indexOfScalar(u8, spec, '@');
        const cidr = if (at) |i| spec[0..i] else spec;
        const ports = if (at) |i| spec[i + 1 ..] else "*";
        if (std.mem.eql(u8, cidr, "any")) {
            try rules.print(alloc, "{s} 0.0.0.0/0 {s}\n{s} ::/0 {s}\n", .{ kind.rule, ports, kind.rule, ports });
        } else {
            try rules.print(alloc, "{s} {s} {s}\n", .{ kind.rule, cidr, ports });
        }
        return true;
    }
    return false;
}

/// Background workers of the V8 platform (garbage collection, compilation): `ORIGINE_V8_WORKERS=n`.
/// 0 lets V8 choose from the CPU count. The default is 1, enough for one isolate; a program that
/// runs several (`api.isolate`) may want more. A value that is not a number is ignored.
fn v8Workers(environ: *const std.process.Environ.Map) u32 {
    const text = environ.get("ORIGINE_V8_WORKERS") orelse return 1;
    return std.fmt.parseInt(u32, text, 10) catch 1;
}

/// Builds the host every entry point runs with: the working directory read/write with sync and
/// async access, all `user_args`, and the whole environment. `env` is caller-owned storage.
fn createHost(
    alloc: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    user_args: []const []const u8,
    env: []m.Api.EnvPair,
    cwd: m.sys.Dir,
    net: m.Api.NetConfig,
    isolates: m.Api.IsolateConfig,
) !*m.Api.Host {
    const keys = environ.keys();
    const values = environ.values();
    for (keys, values, env) |key, value, *out| out.* = .{ .name = key, .value = value };
    return m.Api.Host.create(alloc, .{ .args = user_args, .env = env, .fs = .{ .root = cwd }, .net = net, .runtime = .{}, .isolates = isolates });
}

/// Starts the REPL with the same host API as an init module: `api` is a global and `import`
/// resolves `origine:@std/*` and files under the working directory. Borrows everything through return.
fn runRepl(
    alloc: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    engine: Engine,
    net: m.Api.NetConfig,
    trace: *StartupTrace,
    buffer_allocator: v8.ArrayBuffer.Allocator,
    engine_snapshot: ?[]align(16) const u8,
) !void {
    const env = try alloc.alloc(m.Api.EnvPair, environ.keys().len);
    defer alloc.free(env);
    var cwd = try m.sys.Dir.cwd().openDir(".", .{ .iterate = true });
    defer cwd.close();
    const host = try createHost(alloc, environ, &.{}, env, cwd, net, .{ .platform = engine.platform, .array_buffer_allocator = buffer_allocator, .engine_snapshot = engine_snapshot });
    var rt: ?*m.Runtime = null;
    // The host releases V8 handles, so it goes before the runtime.
    defer {
        host.destroy();
        if (rt) |runtime| runtime.destroy();
    }
    const references = try host.externalReferences(alloc);
    defer alloc.free(references);
    rt = try m.Runtime.create(alloc, .{
        .array_buffer_allocator = .{ .borrowed = buffer_allocator },
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
/// environment). The evaluated init graph is cached as a snapshot in the global cache (`cache_dir.zig`):
/// the first run creates it, later runs restore it instead of evaluating the
/// init again. Borrows everything through return.
fn runInit(
    alloc: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    engine: Engine,
    args: []const [:0]const u8,
    net: m.Api.NetConfig,
    trace: *StartupTrace,
    buffer_allocator: v8.ArrayBuffer.Allocator,
    engine_snapshot: ?[]align(16) const u8,
) !void {
    const user_args = try alloc.alloc([]const u8, args.len - 1);
    defer alloc.free(user_args);
    for (args[1..], user_args) |arg, *out| out.* = arg;
    const env = try alloc.alloc(m.Api.EnvPair, environ.keys().len);
    defer alloc.free(env);
    var cwd = try m.sys.Dir.cwd().openDir(".", .{ .iterate = true });
    defer cwd.close();
    const host = try createHost(alloc, environ, user_args, env, cwd, net, .{ .platform = engine.platform, .array_buffer_allocator = buffer_allocator, .engine_snapshot = engine_snapshot });
    // The host releases V8 handles, so it goes before the runtime; the snapshot image backs
    // the runtime's heap, so it goes after.
    var image: ?m.init_snapshot.Image = null;
    var rt: ?*m.Runtime = null;
    // The global cache (see `cache_dir.zig`): where it is, how big, and which of its two uses are on.
    var settings = try m.Api.cache_dir.settingsFrom(alloc, environ);
    defer settings.deinit(alloc);
    const cache: ?m.sys.Dir = if (settings.dir_path) |path| m.Api.cache_dir.openDir(path) else null;
    defer if (cache) |dir| dir.close();
    const snapshotting = settings.snapshot and cache != null;
    const code_caching = settings.code and cache != null;
    const may_store = settings.budget != 0;
    var code_cache: m.Api.init_cache.CodeCacheState = undefined;
    if (cache) |dir| {
        code_cache = m.Api.init_cache.CodeCacheState.init(host, dir);
        code_cache.writable = may_store;
    }
    defer {
        host.destroy();
        if (rt) |runtime| runtime.destroy();
        if (image) |*cached| cached.deinit();
    }
    // The callbacks that may live in a snapshot's heap: the same table must be given to the
    // isolate that makes it and to the one that restores it.
    const references = try host.externalReferences(alloc);
    defer alloc.free(references);
    if (snapshotting) image = initSnapshot(alloc, environ, host, cache.?, may_store, references, args[1], buffer_allocator, engine_snapshot);
    trace.mark("init_snapshot");
    // V8 takes a code cache only from an isolate booted from the same startup blob: name the files by it.
    if (code_caching) if (image) |*cached| {
        code_cache.boot = m.Api.init_cache.blobDigest(cached.blob);
    };
    rt = try m.Runtime.create(alloc, .{
        .array_buffer_allocator = .{ .borrowed = buffer_allocator },
        .snapshot = if (image) |*cached| cached.blob else engine_snapshot,
        .external_references = m.init_snapshot.referenceTable(references),
    });
    trace.mark("runtime_isolate");
    var options = host.initOptions();
    if (image) |*cached| options.init_snapshot = &cached.table;
    if (code_caching) options.code_cache = code_cache.hook();
    const scope = try rt.?.createScope(options);
    trace.mark("create_scope");
    var error_info: m.ErrorInfo = .{};
    defer error_info.deinit();
    host.run(scope, engine.platform, args[1], &error_info) catch |err| {
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
    if (code_caching) {
        _ = scope.flushCodeCache();
        host.flushGlueCache(scope);
    }
    // A run that stored something may have taken the cache over its budget: drop the least recently
    // used files. A fully warm run stores nothing and never scans the directory.
    if (cache) |dir| if (m.Api.cache_dir.wroteSomething()) {
        const stats = m.Api.cache_dir.evict(alloc, dir, settings.budget, m.sys.realtimeNs()) catch |err| blk: {
            if (environ.get("ORIGINE_SNAPSHOT_LOG") != null) m.stderr.print("cache: not trimmed ({s})\n", .{@errorName(err)});
            break :blk null;
        };
        if (stats) |done| if (environ.get("ORIGINE_SNAPSHOT_LOG") != null) {
            m.stderr.print("cache: {d} files, {d} bytes, deleted {d} ({d} bytes)\n", .{ done.files, done.bytes, done.deleted, done.freed });
        };
    };
}

/// The cached snapshot of the init graph at `specifier`, created and (unless `may_store` is false,
/// a budget of 0) stored in the cache directory `cache` on a miss. Null means "run without": an
/// init that cannot be snapshotted (it throws, waits on I/O or imports a host module) or any other
/// failure; the normal path then reports whatever is wrong with the init. With ORIGINE_SNAPSHOT_LOG
/// set, says why on stderr. Borrows everything through return.
fn initSnapshot(
    alloc: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    host: *m.Api.Host,
    cache: m.sys.Dir,
    may_store: bool,
    references: []const ?*const anyopaque,
    specifier: []const u8,
    buffer_allocator: v8.ArrayBuffer.Allocator,
    engine_snapshot: ?[]align(16) const u8,
) ?m.init_snapshot.Image {
    const verbose = environ.get("ORIGINE_SNAPSHOT_LOG") != null;
    var entry = m.Api.init_cache.entryFor(alloc, host, specifier) catch return null;
    defer entry.deinit();
    var miss: m.Api.init_cache.Miss = undefined;
    if (m.Api.init_cache.load(alloc, cache, &entry, m.Api.init_cache.sourceHasher(host), &miss)) |hit| {
        if (verbose) m.stderr.print("init snapshot: reused {s}\n", .{entry.name});
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
        .array_buffer_allocator = buffer_allocator,
    }) catch |err| {
        if (verbose) m.stderr.print("init snapshot: not created ({s})\n", .{@errorName(err)});
        return null;
    };
    if (!may_store) return created;
    m.Api.init_cache.store(alloc, cache, &entry, &created, 0) catch |err| {
        if (verbose) m.stderr.print("init snapshot: not stored ({s})\n", .{@errorName(err)});
        return created;
    };
    if (verbose) m.stderr.print("init snapshot: created {s}\n", .{entry.name});
    return created;
}

/// The frozen-intrinsics startup snapshot generated at build time (see build.zig and
/// snapshot_tool.zig); empty when the build could not generate one (cross builds). With
/// `-Dengine_snapshot=compressed` it is LZ4-compressed (`lib/lz4`) and expanded at startup.
const embedded_snapshot = if (build_options.has_snapshot) @embedFile("engine_snapshot") else "";
const snapshot_compressed = build_options.has_snapshot and build_options.engine_snapshot_compressed;

/// The uncompressed blob in `align(16)` as V8 requires (empty when compressed or absent).
const embedded_raw: [if (snapshot_compressed) 0 else embedded_snapshot.len]u8 align(16) =
    if (snapshot_compressed) .{} else embedded_snapshot.*;

/// Returns the embedded snapshot, or null to use V8's built-in seed (no embedded blob). A compressed blob is expanded into a 16-byte
/// aligned buffer that lives for the rest of the process; the data is produced by the build, so a
/// blob that fails to expand is a build defect and aborts.
fn embeddedSnapshot(alloc: std.mem.Allocator) ?[]align(16) const u8 {
    if (embedded_snapshot.len == 0) return null;
    if (snapshot_compressed) {
        return lz4.unpack(alloc, embedded_snapshot) catch |err| std.debug.panic("embedded engine snapshot: {s}", .{@errorName(err)});
    }
    return &embedded_raw;
}
