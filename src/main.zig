//! origine entry point: evaluate a JavaScript file or start a managed REPL.
const std = @import("std");
const v8 = @import("@v8");
const m = @import("@managed");
const eu = @import("@util");
const StartupTrace = @import("@diagnostics").StartupTrace;
const Engine = @import("@engine").Engine;
const build_options = @import("build_options");
var io_runtime: std.Io.Threaded = undefined;

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
    const text = value.deref().toString(ctx) orelse {
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
    const rt = try m.Runtime.create(alloc, .{ .array_buffer_allocator = .{ .zig = alloc }, .snapshot = snapshot });
    trace.mark("runtime_isolate");
    defer rt.destroy();
    if (args.len > 1) {
        trace.report();
        return runInit(alloc, init, rt, engine, args);
    }
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
/// read/write with sync access, all arguments after the init path, and the whole
/// environment). Borrows everything through return.
fn runInit(alloc: std.mem.Allocator, init: std.process.Init, rt: *m.Runtime, engine: Engine, args: []const [:0]const u8) !void {
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
    const host = try m.Api.Host.create(alloc, .{ .io = io_runtime.io(), .args = user_args, .env = env, .fs = .{ .root = cwd } });
    defer host.destroy();
    const scope = try rt.createScope(host.initOptions());
    var error_info: m.ErrorInfo = .{};
    defer error_info.deinit();
    host.run(scope, engine.platform, args[1], &error_info) catch |err| {
        print("{s}\n", .{@errorName(err)});
        if (error_info.exception) |value| show(scope, value);
        return err;
    };
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
