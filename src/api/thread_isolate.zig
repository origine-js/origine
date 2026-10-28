//! A V8 isolate with its own `Runtime`, `Host` and I/O runtimes on a thread of its own: the native
//! half of `api.isolate`. The thread runs the same lifecycle as the process entry point (create
//! the isolate, evaluate `init`, call its `main(api)`, settle) and then tears everything down.
//!
//! Lifetime rules, all enforced here or by the caller:
//! - The `Engine` (V8 platform) outlives every `ThreadIsolate`: `join` each one before `Engine.deinit`.
//! - Everything in `Options` that is borrowed (`platform`, `array_buffer_allocator`, `engine_snapshot`,
//!   `fs.root`) must outlive the thread, i.e. until `join` returns. `init`, `args` and `env` are copied.
//! - `terminate` may be called from any thread until `destroy`; the thread observes it at the next
//!   turn of its settle loop (at most `platform_poll_ns` later when it is blocked on I/O).
const std = @import("std");
const v8 = @import("@v8");
const host_api = @import("host.zig");
const env_api = @import("env.zig");
const Host = host_api.Host;
const Runtime = @import("../managed/runtime.zig").Runtime;
const init_snapshot = @import("../managed/init_snapshot.zig");
const ErrorInfo = @import("../managed/errors.zig").ErrorInfo;
const abi = @import("api_abi.zig");
const snapshot_api = @import("snapshot.zig");

pub const Options = struct {
    /// Module specifier of the child's init module (its exported `main(api)` runs). Copied.
    init: []const u8,
    args: []const []const u8 = &.{},
    env: []const env_api.Pair = &.{},
    /// Borrowed until `join` returns.
    fs: ?host_api.FsConfig = null,
    runtime: ?host_api.RuntimeConfig = .{},
    /// Borrowed until `join` returns. Must be thread-safe (the process-wide one is).
    array_buffer_allocator: v8.ArrayBuffer.Allocator,
    platform: v8.Platform,
    /// The shared read-only engine snapshot, or null for V8's built-in seed.
    engine_snapshot: ?[]align(16) const u8 = null,
    /// What the child's `api.isolate.parent` is made of; null for a plain thread isolate.
    link: ?host_api.ParentLink = null,
    /// An init snapshot (or bare blob) to start from, instead of the engine snapshot. The thread owns
    /// this reference and releases it when the handle is destroyed.
    snapshot: ?*snapshot_api.Record = null,
    /// Lets the child create isolates in turn (null: it cannot).
    isolates: ?host_api.IsolateConfig = null,
    /// Channel ends closed when the thread is done (after its outcome is recorded), whether or not
    /// the child took them over. Copied.
    release: []const u32 = &.{},
};

/// How the thread ended. `failed` carries the error name in `failure`.
pub const Outcome = enum { completed, failed, terminated };

/// Hands out the identities of isolates made by `ThreadIsolate.spawn`: 1, 2, ... (the first isolate is 0).
var next_identity: std.atomic.Value(u32) = .init(1);

pub const ThreadIsolate = struct {
    allocator: std.mem.Allocator,
    /// This isolate's identity (`event.identity` of the messages it sends), unique in the process.
    id: u32,
    options: Options,
    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    /// Spinlock around `isolate`: `terminate` must not race the thread disposing it.
    lock: std.atomic.Value(bool) = .init(false),
    isolate: ?v8.Isolate = null,
    /// Set (with release ordering) once the thread recorded its outcome and is about to exit.
    finished: std.atomic.Value(bool) = .init(false),
    outcome: Outcome = .completed,
    failure_buffer: [64]u8 = undefined,
    failure_len: usize = 0,

    /// Copies the options and starts the thread. Returns a heap object at a stable address; release
    /// it with `join` then `destroy`. The thread starts running `init` immediately.
    pub fn spawn(allocator: std.mem.Allocator, options: Options) !*ThreadIsolate {
        const self = try allocator.create(ThreadIsolate);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .id = next_identity.fetchAdd(1, .monotonic), .options = options };
        if (options.link) |link| self.options.link = .{ .data = link.data, .identity = self.id };
        self.options.init = try allocator.dupe(u8, options.init);
        errdefer allocator.free(self.options.init);
        const args = try allocator.alloc([]const u8, options.args.len);
        var made_args: usize = 0;
        errdefer {
            for (args[0..made_args]) |arg| allocator.free(arg);
            allocator.free(args);
        }
        for (options.args, args) |arg, *out| {
            out.* = try allocator.dupe(u8, arg);
            made_args += 1;
        }
        self.options.args = args;
        const env = try allocator.alloc(env_api.Pair, options.env.len);
        var made_env: usize = 0;
        errdefer {
            for (env[0..made_env]) |pair| {
                allocator.free(pair.name);
                allocator.free(pair.value);
            }
            allocator.free(env);
        }
        for (options.env, env) |pair, *out| {
            const name = try allocator.dupe(u8, pair.name);
            errdefer allocator.free(name);
            out.* = .{ .name = name, .value = try allocator.dupe(u8, pair.value) };
            made_env += 1;
        }
        self.options.env = env;
        self.options.release = try allocator.dupe(u32, options.release);
        errdefer allocator.free(self.options.release);
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
        return self;
    }

    /// Thread-safe. Asks the isolate to stop: the running JavaScript is interrupted and the settle
    /// loop returns. Idempotent; `join` still has to be called.
    pub fn terminate(self: *ThreadIsolate) void {
        self.stop.store(true, .release);
        self.acquire();
        defer self.release();
        if (self.isolate) |isolate| isolate.terminateExecution();
    }

    /// Blocks until the thread has torn its isolate down; safe to call once.
    pub fn join(self: *ThreadIsolate) Outcome {
        if (self.thread) |thread| thread.join();
        self.thread = null;
        return self.outcome;
    }

    /// The error name when the outcome is `failed`. Valid until `destroy`.
    pub fn failure(self: *const ThreadIsolate) ?[]const u8 {
        return if (self.outcome == .failed) self.failure_buffer[0..self.failure_len] else null;
    }

    /// Frees the handle; `join` first.
    pub fn destroy(self: *ThreadIsolate) void {
        std.debug.assert(self.thread == null);
        const allocator = self.allocator;
        for (self.options.args) |arg| allocator.free(arg);
        allocator.free(self.options.args);
        for (self.options.env) |pair| {
            allocator.free(pair.name);
            allocator.free(pair.value);
        }
        allocator.free(self.options.env);
        allocator.free(self.options.release);
        allocator.free(self.options.init);
        if (self.options.snapshot) |held| held.release();
        allocator.destroy(self);
    }

    fn acquire(self: *ThreadIsolate) void {
        while (self.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }

    fn release(self: *ThreadIsolate) void {
        self.lock.store(false, .release);
    }

    fn threadMain(self: *ThreadIsolate) void {
        // After the outcome is recorded: a peer woken by a closed end then reads the final outcome.
        defer {
            self.finished.store(true, .release);
            for (self.options.release) |handle| abi.origine_api_channel_close(handle);
            // A stashed message the child never took (it died first) is dropped, closing the ports in it.
            if (self.options.link) |link| if (link.data != 0) abi.origine_api_stash_discard(link.data);
        }
        self.execute() catch |err| {
            if (self.stop.load(.acquire)) {
                self.outcome = .terminated;
                return;
            }
            const name = @errorName(err);
            const len = @min(name.len, self.failure_buffer.len);
            @memcpy(self.failure_buffer[0..len], name[0..len]);
            self.failure_len = len;
            self.outcome = .failed;
            return;
        };
        self.outcome = if (self.stop.load(.acquire)) .terminated else .completed;
    }

    fn execute(self: *ThreadIsolate) !void {
        const alloc = self.allocator;
        const options = self.options;
        const host = try Host.create(alloc, .{
            .args = options.args,
            .env = options.env,
            .fs = options.fs,
            .runtime = options.runtime,
            .link = self.options.link,
            .isolates = options.isolates,
        });
        host.stop = &self.stop;
        var rt: ?*Runtime = null;
        // The host releases V8 handles, so it goes before the runtime.
        defer {
            host.destroy();
            if (rt) |runtime| {
                self.acquire();
                self.isolate = null;
                self.release();
                runtime.destroy();
            }
        }
        const references = try host.externalReferences(alloc);
        defer alloc.free(references);
        rt = try Runtime.create(alloc, .{
            .array_buffer_allocator = .{ .borrowed = options.array_buffer_allocator },
            .snapshot = if (options.snapshot) |held| held.blob() else options.engine_snapshot,
            .external_references = init_snapshot.referenceTable(references),
        });
        {
            self.acquire();
            defer self.release();
            self.isolate = rt.?.isolate;
        }
        // A terminate that arrived before the isolate was published has set `stop` only.
        if (self.stop.load(.acquire)) return error.Terminated;
        var scope_options = host.initOptions();
        if (options.snapshot) |held| if (held.image) |*image| {
            scope_options.init_snapshot = &image.table;
        };
        const scope = try rt.?.createScope(scope_options);
        var error_info: ErrorInfo = .{};
        defer error_info.deinit();
        try host.run(scope, options.platform, options.init, &error_info);
    }
};
