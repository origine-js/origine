//! Host side of the guest-visible `api` object (draft-1): env, fs, scope.
//!
//! The Zig `Host` owns all authority (directory handles, grants, child scopes).
//! Guest code only ever holds native functions whose V8 External data points at a
//! grant or per-scope state record, plus plain descriptors that name things inside
//! one grant. `api.js` shapes the surface; every native validates its own inputs.
//!
//! Error protocol: natives take a `Uint32Array` as argument 0. A failure writes a
//! non-zero `Errno` into element 0 and returns undefined; success leaves 0.
const std = @import("std");
const v8 = @import("@v8");
const Runtime = @import("runtime.zig").Runtime;
const Scope = @import("scope.zig").Scope;
const module_types = @import("module_types.zig");
const import_map = @import("import_map.zig");
const ErrorInfo = @import("errors.zig").ErrorInfo;

pub const std_io_id = "@engine/std/io";
pub const std_io_source = @embedFile("std_io.js");
const glue_source = @embedFile("api.js");
/// Largest file `fileReadAll` returns, regardless of the requested limit.
const max_read_bytes: usize = 256 << 20;

/// Numeric error codes shared with `std_io.js` (`IoError`). Names match Zig error
/// names so `errnoOf` can map by name.
pub const Errno = enum(u32) {
    ok = 0,
    FileNotFound = 1,
    AccessDenied = 2,
    NotDir = 3,
    IsDir = 4,
    PathAlreadyExists = 5,
    BadHandle = 6,
    StaleHandle = 7,
    InvalidPath = 8,
    NoSpaceLeft = 9,
    Unsupported = 10,
    FileTooBig = 11,
    Unexpected = 255,
};

/// Maps any Zig error to an `Errno` by name; unknown errors become `Unexpected`.
pub fn errnoOf(err: anyerror) Errno {
    const name = @errorName(err);
    inline for (std.enums.values(Errno)) |tag| {
        if (tag != .ok and std.mem.eql(u8, @tagName(tag), name)) return tag;
    }
    if (std.mem.eql(u8, name, "PermissionDenied") or std.mem.eql(u8, name, "ReadOnlyFileSystem")) return .AccessDenied;
    if (std.mem.eql(u8, name, "UnsupportedExport")) return .Unsupported;
    return .Unexpected;
}

pub const EnvPair = struct { name: []const u8, value: []const u8 };

/// What the host grants to `fs.request`. `root` is borrowed and must outlive the Host.
pub const FsConfig = struct {
    root: std.Io.Dir,
    write: bool = true,
    sync: bool = true,
};

pub const Config = struct {
    io: std.Io,
    args: []const []const u8 = &.{},
    env: []const EnvPair = &.{},
    fs: ?FsConfig = null,
};

const Child = struct { scope: *Scope, parent: *Scope, main: []u8, closed: bool = false };

const ScopeState = struct { host: *Host, scope: *Scope };

const FsGrant = struct {
    host: *Host,
    id: u32,
    root: std.Io.Dir,
    write: bool,
    files: std.ArrayList(?std.Io.File) = .empty,
    dirs: std.ArrayList(?std.Io.Dir) = .empty,

    fn deinit(self: *FsGrant) void {
        const io = self.host.io;
        for (self.files.items) |slot| if (slot) |file| file.close(io);
        for (self.dirs.items) |slot| if (slot) |dir| dir.close(io);
        self.root.close(io);
        self.files.deinit(self.host.allocator);
        self.dirs.deinit(self.host.allocator);
    }

    /// `{fs:0,id:0}` is the cwd sentinel and names this grant's root; any other
    /// descriptor must have been issued by this grant.
    fn dirFor(self: *FsGrant, fs_id: u32, id: u32) !std.Io.Dir {
        if (fs_id == 0 and id == 0) return self.root;
        if (fs_id != self.id) return error.BadHandle;
        if (id == 0) return self.root;
        if (id > self.dirs.items.len) return error.BadHandle;
        return self.dirs.items[id - 1] orelse error.BadHandle;
    }

    fn fileFor(self: *FsGrant, fs_id: u32, id: u32) !std.Io.File {
        if (fs_id != self.id or id == 0 or id > self.files.items.len) return error.BadHandle;
        return self.files.items[id - 1] orelse error.BadHandle;
    }

    fn storeFile(self: *FsGrant, file: std.Io.File) !u32 {
        for (self.files.items, 0..) |slot, index| if (slot == null) {
            self.files.items[index] = file;
            return @intCast(index + 1);
        };
        try self.files.append(self.host.allocator, file);
        return @intCast(self.files.items.len);
    }

    fn storeDir(self: *FsGrant, dir: std.Io.Dir) !u32 {
        for (self.dirs.items, 0..) |slot, index| if (slot == null) {
            self.dirs.items[index] = dir;
            return @intCast(index + 1);
        };
        try self.dirs.append(self.host.allocator, dir);
        return @intCast(self.dirs.items.len);
    }
};

/// Rejects NUL, absolute paths and `..` components. Lexical only: symlinks inside
/// the root are not resolved here (draft-1 limitation, see docs/api-design.md).
fn cleanPath(path: []const u8) !void {
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    if (path.len != 0 and path[0] == '/') return error.InvalidPath;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (std.mem.eql(u8, part, "..")) return error.InvalidPath;
}

const JsLoader = struct {
    host: *Host,
    parent: *Scope,
    function: v8.Global.Of(v8.Function),
};

const PendingLoad = struct { host: *Host, token: module_types.LoadToken };

const RunState = struct {
    host: *Host,
    resolver: v8.Global.Of(v8.Promise.Resolver),
    done: bool = false,
};

pub const Host = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    env: []const EnvPair,
    fs: ?FsConfig,
    grants: std.ArrayList(*FsGrant) = .empty,
    states: std.ArrayList(*ScopeState) = .empty,
    children: std.ArrayList(Child) = .empty,
    loaders: std.ArrayList(*JsLoader) = .empty,
    runs: std.ArrayList(*RunState) = .empty,
    next_fs_id: u32 = 1,
    /// True while a JS loader callback runs inside Runtime.pump's scope iteration;
    /// creating a scope then would invalidate that iteration.
    in_loader: bool = false,

    /// Borrows config contents until `destroy`. Returns a heap Host at a stable
    /// address. Release all V8 handles it made (`destroy`) before `Runtime.destroy`.
    pub fn create(allocator: std.mem.Allocator, config: Config) !*Host {
        const host = try allocator.create(Host);
        host.* = .{ .allocator = allocator, .io = config.io, .args = config.args, .env = config.env, .fs = config.fs };
        return host;
    }

    /// Closes every handle and frees all host records. Must run before
    /// `Runtime.destroy` (it releases V8 persistent handles).
    pub fn destroy(self: *Host) void {
        const alloc = self.allocator;
        for (self.grants.items) |grant| {
            grant.deinit();
            alloc.destroy(grant);
        }
        self.grants.deinit(alloc);
        for (self.states.items) |state| alloc.destroy(state);
        self.states.deinit(alloc);
        for (self.children.items) |child| alloc.free(child.main);
        self.children.deinit(alloc);
        for (self.loaders.items) |loader| {
            loader.function.deinit();
            alloc.destroy(loader);
        }
        self.loaders.deinit(alloc);
        for (self.runs.items) |pending| {
            if (!pending.done) pending.resolver.deinit();
            alloc.destroy(pending);
        }
        self.runs.deinit(alloc);
        alloc.destroy(self);
    }

    /// Resolver and loader for the init scope: serves `@engine/std/io` and reads
    /// other modules from the process working directory. Borrows self.
    pub fn initOptions(self: *Host) Scope.Options {
        return .{
            .resolver = .{ .data = self, .resolve = initResolve },
            .loader = .{ .data = self, .load = initLoad },
        };
    }

    /// Builds the frozen `api` object in `scope`'s realm. Returns a caller-owned
    /// persistent handle (release before Runtime.destroy). Error details follow
    /// ErrorInfo ownership.
    pub fn install(self: *Host, scope: *Scope, error_info: ?*ErrorInfo) !v8.Global.Of(v8.Value) {
        const state = try self.allocator.create(ScopeState);
        errdefer self.allocator.destroy(state);
        state.* = .{ .host = self, .scope = scope };
        try self.states.append(self.allocator, state);
        var session: Scope.Session = undefined;
        session.init(scope);
        defer session.deinit();
        errdefer session.retainException(error_info);
        const isolate = session.isolate();
        const ctx = session.ctx;
        const native = v8.Object.init(isolate);
        const env = v8.Object.init(isolate);
        setFn(ctx, env, "args", envArgs, state);
        setFn(ctx, env, "get", envGet, state);
        setFn(ctx, env, "list", envList, state);
        try setProp(ctx, native, "env", env.value);
        setFn(ctx, native, "fsRequest", fsRequest, state);
        const scopes = v8.Object.init(isolate);
        setFn(ctx, scopes, "create", scopeCreate, state);
        setFn(ctx, scopes, "preload", scopePreload, state);
        setFn(ctx, scopes, "run", scopeRun, state);
        setFn(ctx, scopes, "close", scopeClose, state);
        try setProp(ctx, native, "scope", scopes.value);
        const script = v8.Script.compile(ctx, v8.String.initUtf8(isolate, glue_source), scope.scriptOrigin("engine:api.js", false)) orelse return error.JavaScriptException;
        const glue = v8.Function.from_opaque((script.run(ctx) orelse return error.JavaScriptException).data.handle) orelse return error.BootstrapFailed;
        const api = glue.call(ctx, v8.Primitive.initUndefined(isolate).value, &.{native.value}) orelse return error.JavaScriptException;
        try scope.hardenLocal(api);
        return .new(isolate, api);
    }

    /// Lifecycle driver: evaluates `init_specifier` as a module in `scope` (which
    /// must have been created with `initOptions`), then calls its exported `main`
    /// with the root `api` and pumps until it settles. Returns error.InitFailed or
    /// error.MainFailed with the rejection/exception in `error_info`.
    pub fn run(self: *Host, scope: *Scope, platform: v8.Platform, init_specifier: []const u8, error_info: ?*ErrorInfo) !void {
        const rt = scope.runtime;
        const api = try self.install(scope, error_info);
        defer api.deinit();
        const loading = try scope.importModule(init_specifier, error_info);
        defer loading.deinit();
        try settle(rt, platform, loading);
        const main_result = blk: {
            var session: Scope.Session = undefined;
            session.init(scope);
            defer session.deinit();
            const promise = loading.deref();
            if (promise.state() == .Rejected) {
                if (error_info) |out| if (out.exception == null) {
                    out.exception = .new(session.isolate(), promise.result());
                };
                return error.InitFailed;
            }
            const namespace = promise.result().toObject(session.ctx) orelse return error.InitFailed;
            const main_value = namespace.get(session.ctx, v8.String.initUtf8(session.isolate(), "main").name.primitive.value) orelse return error.InitFailed;
            const main_fn = v8.Function.from_opaque(main_value.data.handle) orelse return error.MainMissing;
            errdefer session.retainException(error_info);
            const result = main_fn.call(session.ctx, v8.Primitive.initUndefined(session.isolate()).value, &.{api.deref()}) orelse return error.MainFailed;
            break :blk v8.Global.Of(v8.Value).new(session.isolate(), result);
        };
        defer main_result.deinit();
        var wrapper: ?v8.Global.Of(v8.Promise) = null;
        defer if (wrapper) |w| w.deinit();
        {
            var session: Scope.Session = undefined;
            session.init(scope);
            defer session.deinit();
            const value = main_result.deref();
            if (value.isPromise()) wrapper = .new(session.isolate(), v8.Promise.from_opaque(value.data.handle).?);
        }
        if (wrapper) |promise| {
            try settle(rt, platform, promise);
            var session: Scope.Session = undefined;
            session.init(scope);
            defer session.deinit();
            if (promise.deref().state() == .Rejected) {
                if (error_info) |out| if (out.exception == null) {
                    out.exception = .new(session.isolate(), promise.deref().result());
                };
                return error.MainFailed;
            }
        } else rt.pumpPlatform(platform);
    }

    fn settle(rt: *Runtime, platform: v8.Platform, promise: v8.Global.Of(v8.Promise)) !void {
        while (true) {
            rt.pumpPlatform(platform);
            var session: Runtime.Session = undefined;
            session.init(rt);
            defer session.deinit();
            if (promise.deref().state() != .Pending) return;
            // pump returned with nothing left to run: the promise can never settle.
            if (!platform.pumpMessageLoop(rt.isolate, false)) return error.Stalled;
        }
    }
};

// ---- V8 plumbing ----------------------------------------------------------

fn setProp(ctx: v8.Context, object: v8.Object, name: []const u8, value: v8.Value) !void {
    const isolate = v8.Isolate.getCurrent();
    const ok = object.createDataProperty(ctx, v8.String.initUtf8(isolate, name).name, value) orelse return error.JavaScriptException;
    if (!ok) return error.JavaScriptException;
}

fn setFn(ctx: v8.Context, object: v8.Object, name: []const u8, callback: v8.FunctionCallback, data: ?*anyopaque) void {
    const isolate = v8.Isolate.getCurrent();
    const function = v8.Function.init(ctx, callback, v8.External.init(isolate, data).value.data, 0, .Throw, .HasSideEffect);
    _ = object.createDataProperty(ctx, v8.String.initUtf8(isolate, name).name, function.object.value);
}

fn str(isolate: v8.Isolate, text: []const u8) v8.Value {
    return v8.String.initUtf8(isolate, text).name.primitive.value;
}

fn viewBytes(value: v8.Value) ?[]u8 {
    const view = v8.ArrayBufferView.from_opaque(value.data.handle) orelse return null;
    const length = view.byteLength();
    if (length == 0) return &.{};
    const buffer = view.buffer() orelse return null;
    const base: [*]u8 = @ptrCast(buffer.data() orelse return null);
    return base[view.byteOffset()..][0..length];
}

fn externalPointer(comptime T: type, info: v8.FunctionCallbackInfo) *T {
    return @ptrCast(@alignCast(v8.External.from_opaque(info.data().?.handle).?.pointer().?));
}

/// Per-call argument and result helper. `err` is the Uint32Array in argument 0
/// when present and valid; failures set it and leave the return value undefined.
const Call = struct {
    info: v8.FunctionCallbackInfo,
    isolate: v8.Isolate,
    ctx: v8.Context,
    err: ?[]u32 = null,
    ret: v8.ReturnValue,

    fn init(info: v8.FunctionCallbackInfo) Call {
        const isolate = info.isolate();
        var call: Call = .{ .info = info, .isolate = isolate, .ctx = isolate.getCurrentContext(), .ret = info.retval() };
        const first = info.get_arg(0);
        if (first.isUint32Array()) {
            if (viewBytes(first)) |raw| if (raw.len >= 4) {
                const words: []u32 = @alignCast(std.mem.bytesAsSlice(u32, raw[0 .. raw.len / 4 * 4]));
                call.err = words;
            };
        }
        return call;
    }

    fn clear(self: *Call) void {
        if (self.err) |words| words[0] = 0;
    }

    fn fail(self: *Call, err: anyerror) void {
        if (self.err) |words| {
            words[0] = @intFromEnum(errnoOf(err));
        } else {
            _ = self.isolate.throwException(v8.Exception.typeError(v8.String.initUtf8(self.isolate, "invalid native call")).?);
        }
    }

    fn arg(self: *const Call, index: c_int) v8.Value {
        return self.info.get_arg(index);
    }

    /// Copies a string argument into allocator-owned UTF-8. Caller frees.
    fn string(self: *const Call, index: c_int, allocator: std.mem.Allocator) ![]u8 {
        const value = self.arg(index);
        if (!value.isString()) return error.InvalidPath;
        const text = value.toString(self.ctx) orelse return error.InvalidPath;
        const buffer = try allocator.alloc(u8, text.lenUtf8(self.isolate));
        const written = text.writeUtf8(self.isolate, buffer);
        return buffer[0..written];
    }

    fn uint(self: *const Call, index: c_int) !u32 {
        const value = self.arg(index);
        if (!value.isNumber()) return error.BadHandle;
        return value.u32Value(self.ctx) orelse error.BadHandle;
    }

    fn bytes(self: *const Call, index: c_int) ![]u8 {
        return viewBytes(self.arg(index)) orelse error.InvalidPath;
    }
};

// ---- env ------------------------------------------------------------------

fn envArgs(info: v8.FunctionCallbackInfo) callconv(.c) void {
    const state = externalPointer(ScopeState, info);
    const isolate = info.isolate();
    const ctx = isolate.getCurrentContext();
    const array = v8.Array.init(isolate, @intCast(state.host.args.len));
    for (state.host.args, 0..) |arg, index| _ = array.object.setIndex(ctx, @intCast(index), str(isolate, arg));
    var ret = info.retval();
    ret.set(array.object.value);
}

fn envGet(info: v8.FunctionCallbackInfo) callconv(.c) void {
    const state = externalPointer(ScopeState, info);
    const isolate = info.isolate();
    const ctx = isolate.getCurrentContext();
    var ret = info.retval();
    const value = info.get_arg(0);
    if (!value.isString()) return;
    const key = value.toString(ctx) orelse return;
    const alloc = state.host.allocator;
    const buffer = alloc.alloc(u8, key.lenUtf8(isolate)) catch return;
    defer alloc.free(buffer);
    const name = buffer[0..key.writeUtf8(isolate, buffer)];
    for (state.host.env) |pair| if (std.mem.eql(u8, pair.name, name)) {
        ret.set(str(isolate, pair.value));
        return;
    };
}

fn envList(info: v8.FunctionCallbackInfo) callconv(.c) void {
    const state = externalPointer(ScopeState, info);
    const isolate = info.isolate();
    const ctx = isolate.getCurrentContext();
    const array = v8.Array.init(isolate, @intCast(state.host.env.len));
    for (state.host.env, 0..) |pair, index| _ = array.object.setIndex(ctx, @intCast(index), str(isolate, pair.name));
    var ret = info.retval();
    ret.set(array.object.value);
}

// ---- fs -------------------------------------------------------------------

fn fsRequest(info: v8.FunctionCallbackInfo) callconv(.c) void {
    var call = Call.init(info);
    call.clear();
    const state = externalPointer(ScopeState, info);
    fsRequestImpl(&call, state) catch |err| call.fail(err);
}

fn fsRequestImpl(call: *Call, state: *ScopeState) !void {
    const host = state.host;
    const alloc = host.allocator;
    const config = host.fs orelse return error.AccessDenied;
    var sub: []u8 = &.{};
    defer alloc.free(sub);
    if (call.arg(1).isString()) {
        sub = try call.string(1, alloc);
        try cleanPath(sub);
    }
    const root = try config.root.openDir(host.io, if (sub.len == 0) "." else sub, .{ .iterate = true });
    errdefer root.close(host.io);
    const grant = try alloc.create(FsGrant);
    errdefer alloc.destroy(grant);
    grant.* = .{ .host = host, .id = host.next_fs_id, .root = root, .write = config.write and call.arg(2).booleanValue(call.isolate) };
    try host.grants.append(alloc, grant);
    host.next_fs_id += 1;
    const isolate = call.isolate;
    const ctx = call.ctx;
    const ops = v8.Object.init(isolate);
    try setProp(ctx, ops, "id", v8.Number.initUInt(isolate, grant.id).numeric.primitive.value);
    try setProp(ctx, ops, "sync", v8.Boolean.init(isolate, config.sync).primitive.value);
    setFn(ctx, ops, "openFile", fsOp(opOpenFile), grant);
    setFn(ctx, ops, "openDir", fsOp(opOpenDir), grant);
    setFn(ctx, ops, "stat", fsOp(opStat), grant);
    setFn(ctx, ops, "createDir", fsOp(opCreateDir), grant);
    setFn(ctx, ops, "deleteFile", fsOp(opDeleteFile), grant);
    setFn(ctx, ops, "readDir", fsOp(opReadDir), grant);
    setFn(ctx, ops, "readAll", fsOp(opReadAll), grant);
    setFn(ctx, ops, "writeAll", fsOp(opWriteAll), grant);
    setFn(ctx, ops, "close", fsOp(opClose), grant);
    setFn(ctx, ops, "closeDir", fsOp(opCloseDir), grant);
    call.ret.set(ops.value);
}

fn fsOp(comptime impl: fn (*FsGrant, *Call) anyerror!void) v8.FunctionCallback {
    return struct {
        fn callback(info: v8.FunctionCallbackInfo) callconv(.c) void {
            var call = Call.init(info);
            call.clear();
            impl(externalPointer(FsGrant, info), &call) catch |err| call.fail(err);
        }
    }.callback;
}

fn kindCode(kind: std.Io.File.Kind) u32 {
    return switch (kind) {
        .file => 1,
        .directory => 2,
        .sym_link => 3,
        else => 4,
    };
}

fn opOpenFile(grant: *FsGrant, call: *Call) !void {
    const alloc = grant.host.allocator;
    const io = grant.host.io;
    const dir = try grant.dirFor(try call.uint(1), try call.uint(2));
    const path = try call.string(3, alloc);
    defer alloc.free(path);
    try cleanPath(path);
    if (path.len == 0) return error.InvalidPath;
    const bits = try call.uint(4);
    const writing = bits & 0b1111 != 0;
    if (writing and !grant.write) return error.AccessDenied;
    const file = if (bits & 2 != 0)
        try dir.createFile(io, path, .{ .read = true, .truncate = bits & 4 != 0, .exclusive = bits & 8 != 0 })
    else
        try dir.openFile(io, path, .{ .mode = if (bits & 1 != 0) .read_write else .read_only, .allow_directory = false });
    errdefer file.close(io);
    call.ret.setUint32(try grant.storeFile(file));
}

fn opOpenDir(grant: *FsGrant, call: *Call) !void {
    const alloc = grant.host.allocator;
    const io = grant.host.io;
    const dir = try grant.dirFor(try call.uint(1), try call.uint(2));
    const path = try call.string(3, alloc);
    defer alloc.free(path);
    try cleanPath(path);
    const opened = try dir.openDir(io, if (path.len == 0) "." else path, .{ .iterate = true });
    errdefer opened.close(io);
    call.ret.setUint32(try grant.storeDir(opened));
}

fn opStat(grant: *FsGrant, call: *Call) !void {
    const alloc = grant.host.allocator;
    const io = grant.host.io;
    const dir = try grant.dirFor(try call.uint(1), try call.uint(2));
    const path = try call.string(3, alloc);
    defer alloc.free(path);
    try cleanPath(path);
    const stat = if (path.len == 0) try dir.stat(io) else try dir.statFile(io, path, .{ .follow_symlinks = false });
    const array = v8.Array.init(call.isolate, 2);
    _ = array.object.setIndex(call.ctx, 0, v8.Number.initUInt(call.isolate, kindCode(stat.kind)).numeric.primitive.value);
    _ = array.object.setIndex(call.ctx, 1, v8.Number.init(call.isolate, @floatFromInt(stat.size)).numeric.primitive.value);
    call.ret.set(array.object.value);
}

fn opCreateDir(grant: *FsGrant, call: *Call) !void {
    const alloc = grant.host.allocator;
    if (!grant.write) return error.AccessDenied;
    const dir = try grant.dirFor(try call.uint(1), try call.uint(2));
    const path = try call.string(3, alloc);
    defer alloc.free(path);
    try cleanPath(path);
    if (path.len == 0) return error.InvalidPath;
    try dir.createDir(grant.host.io, path, .default_dir);
}

fn opDeleteFile(grant: *FsGrant, call: *Call) !void {
    const alloc = grant.host.allocator;
    if (!grant.write) return error.AccessDenied;
    const dir = try grant.dirFor(try call.uint(1), try call.uint(2));
    const path = try call.string(3, alloc);
    defer alloc.free(path);
    try cleanPath(path);
    if (path.len == 0) return error.InvalidPath;
    try dir.deleteFile(grant.host.io, path);
}

/// Returns a flat array `[name0, kind0, name1, kind1, ...]`.
fn opReadDir(grant: *FsGrant, call: *Call) !void {
    const io = grant.host.io;
    const dir = try grant.dirFor(try call.uint(1), try call.uint(2));
    const array = v8.Array.init(call.isolate, 0);
    var iterator = dir.iterate();
    var index: u32 = 0;
    while (try iterator.next(io)) |entry| {
        _ = array.object.setIndex(call.ctx, index, str(call.isolate, entry.name));
        _ = array.object.setIndex(call.ctx, index + 1, v8.Number.initUInt(call.isolate, kindCode(entry.kind)).numeric.primitive.value);
        index += 2;
    }
    call.ret.set(array.object.value);
}

fn opReadAll(grant: *FsGrant, call: *Call) !void {
    const alloc = grant.host.allocator;
    const io = grant.host.io;
    const file = try grant.fileFor(try call.uint(1), try call.uint(2));
    const requested = call.arg(3);
    if (!requested.isNumber()) return error.InvalidPath;
    const number = requested.numberValue(call.ctx) orelse return error.InvalidPath;
    // Limit semantics: Infinity = unlimited, otherwise read at most n bytes.
    const limit: usize = if (std.math.isInf(number)) std.math.maxInt(usize) else if (number >= 0) @intFromFloat(@min(number, @as(f64, @floatFromInt(std.math.maxInt(usize) / 2)))) else return error.InvalidPath;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(alloc);
    var buffer: [16 * 1024]u8 = undefined;
    while (list.items.len < limit) {
        const want = @min(buffer.len, limit - list.items.len);
        const count = file.readStreaming(io, &.{buffer[0..want]}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (count == 0) break;
        if (list.items.len + count > max_read_bytes) return error.FileTooBig;
        try list.appendSlice(alloc, buffer[0..count]);
    }
    const store = v8.ArrayBuffer.newWithByteLength(call.isolate, list.items.len) orelse return error.OutOfMemory;
    if (list.items.len != 0) @memcpy(@as([*]u8, @ptrCast(store.data().?))[0..list.items.len], list.items);
    const array = v8.Uint8Array.init(store, 0, list.items.len) orelse return error.OutOfMemory;
    call.ret.set(array.typedArray.arrayBufferView.object.value);
}

fn opWriteAll(grant: *FsGrant, call: *Call) !void {
    const io = grant.host.io;
    if (!grant.write) return error.AccessDenied;
    const file = try grant.fileFor(try call.uint(1), try call.uint(2));
    const data = try call.bytes(3);
    var offset: usize = 0;
    while (offset < data.len) offset += try file.writeStreaming(io, "", &.{data[offset..]}, 1);
}

fn opClose(grant: *FsGrant, call: *Call) !void {
    const file = try grant.fileFor(try call.uint(1), try call.uint(2));
    file.close(grant.host.io);
    grant.files.items[try call.uint(2) - 1] = null;
}

fn opCloseDir(grant: *FsGrant, call: *Call) !void {
    const fs_id = try call.uint(1);
    const id = try call.uint(2);
    if (id == 0) return error.BadHandle; // the root stays open for the grant's lifetime
    const dir = try grant.dirFor(fs_id, id);
    dir.close(grant.host.io);
    grant.dirs.items[id - 1] = null;
}

// ---- scope ----------------------------------------------------------------

fn childFor(state: *ScopeState, id: u32) !*Child {
    const host = state.host;
    if (id == 0 or id > host.children.items.len) return error.BadHandle;
    const child = &host.children.items[id - 1];
    if (child.parent != state.scope) return error.BadHandle;
    if (child.closed) return error.StaleHandle;
    return child;
}

fn scopeCreate(info: v8.FunctionCallbackInfo) callconv(.c) void {
    var call = Call.init(info);
    call.clear();
    scopeCreateImpl(&call, externalPointer(ScopeState, info)) catch |err| call.fail(err);
}

fn scopeCreateImpl(call: *Call, state: *ScopeState) !void {
    const host = state.host;
    const alloc = host.allocator;
    if (host.in_loader) return error.Unsupported;
    var options: Scope.Options = .{};
    var map: ?import_map.ImportMap = null;
    defer if (map) |*owned| owned.deinit();
    const main = try call.string(1, alloc);
    errdefer alloc.free(main);
    if (call.arg(2).isString()) {
        const json = try call.string(2, alloc);
        defer alloc.free(json);
        map = try import_map.ImportMap.parseJson(alloc, json, .{ .base_url = "app:/map.json", .urls = import_map.virtual_urls });
        options.import_map = &map.?;
    }
    var loader: ?*JsLoader = null;
    errdefer if (loader) |made| {
        made.function.deinit();
        alloc.destroy(made);
    };
    if (call.arg(3).isFunction()) {
        const function = v8.Function.from_opaque(call.arg(3).data.handle) orelse return error.InvalidPath;
        loader = try alloc.create(JsLoader);
        loader.?.* = .{ .host = host, .parent = state.scope, .function = .new(call.isolate, function) };
        options.loader = .{ .data = loader, .load = jsLoad };
    }
    try host.children.ensureUnusedCapacity(alloc, 1);
    try host.loaders.ensureUnusedCapacity(alloc, 1);
    const child = try state.scope.runtime.createScope(options);
    host.children.appendAssumeCapacity(.{ .scope = child, .parent = state.scope, .main = main });
    if (loader) |made| host.loaders.appendAssumeCapacity(made);
    loader = null;
    call.ret.setUint32(@intCast(host.children.items.len));
}

fn scopePreload(info: v8.FunctionCallbackInfo) callconv(.c) void {
    var call = Call.init(info);
    call.clear();
    scopePreloadImpl(&call, externalPointer(ScopeState, info)) catch |err| call.fail(err);
}

fn scopePreloadImpl(call: *Call, state: *ScopeState) !void {
    const alloc = state.host.allocator;
    const child = try childFor(state, try call.uint(1));
    const source = try call.string(2, alloc);
    defer alloc.free(source);
    const origin = try call.string(3, alloc);
    defer alloc.free(origin);
    const values = call.arg(4);
    if (!values.isUndefined()) try state.scope.hardenLocal(values);
    var session: Scope.Session = undefined;
    session.init(child.scope);
    defer session.deinit();
    const isolate = session.isolate();
    const script = v8.Script.compile(session.ctx, v8.String.initUtf8(isolate, source), child.scope.scriptOrigin(origin, false)) orelse return error.InvalidPath;
    const function = v8.Function.from_opaque((script.run(session.ctx) orelse return error.Unexpected).data.handle) orelse return error.InvalidPath;
    _ = function.call(session.ctx, v8.Primitive.initUndefined(isolate).value, &.{values}) orelse return error.Unexpected;
}

fn scopeRun(info: v8.FunctionCallbackInfo) callconv(.c) void {
    var call = Call.init(info);
    call.clear();
    scopeRunImpl(&call, externalPointer(ScopeState, info)) catch |err| call.fail(err);
}

fn scopeRunImpl(call: *Call, state: *ScopeState) !void {
    const host = state.host;
    const alloc = host.allocator;
    const child = try childFor(state, try call.uint(1));
    const resolver = v8.Promise.Resolver.init(call.ctx) orelse return error.Unexpected;
    const run = try alloc.create(RunState);
    errdefer alloc.destroy(run);
    run.* = .{ .host = host, .resolver = .new(call.isolate, resolver) };
    errdefer run.resolver.deinit();
    try host.runs.append(alloc, run);
    errdefer _ = host.runs.pop();
    const loading = try child.scope.importModule(child.main, null);
    defer loading.deinit();
    const data = v8.External.init(call.isolate, run).value.data;
    const on_fulfilled = v8.Function.init(call.ctx, runFulfilled, data, 1, .Throw, .HasSideEffect);
    const on_rejected = v8.Function.init(call.ctx, runRejected, data, 1, .Throw, .HasSideEffect);
    {
        var session: Scope.Session = undefined;
        session.init(child.scope);
        defer session.deinit();
        _ = loading.deref().then2(session.ctx, on_fulfilled, on_rejected) orelse return error.Unexpected;
    }
    call.ret.set(resolver.getPromise().object.value);
}

fn runFulfilled(info: v8.FunctionCallbackInfo) callconv(.c) void {
    const run = externalPointer(RunState, info);
    if (run.done) return;
    run.done = true;
    const isolate = info.isolate();
    _ = run.resolver.deref().resolve(isolate.getCurrentContext(), v8.Primitive.initUndefined(isolate).value);
    run.resolver.deinit();
}

fn runRejected(info: v8.FunctionCallbackInfo) callconv(.c) void {
    const run = externalPointer(RunState, info);
    if (run.done) return;
    run.done = true;
    const isolate = info.isolate();
    const ctx = isolate.getCurrentContext();
    // Child-realm errors never cross; the parent gets a fresh description.
    const failure = v8.Object.init(isolate);
    var message: v8.Value = str(isolate, "module evaluation failed");
    if (info.get_arg(0).toDetailString(ctx)) |text| message = text.name.primitive.value;
    _ = failure.createDataProperty(ctx, v8.String.initUtf8(isolate, "errno").name, v8.Number.initUInt(isolate, @intFromEnum(Errno.Unexpected)).numeric.primitive.value);
    _ = failure.createDataProperty(ctx, v8.String.initUtf8(isolate, "name").name, str(isolate, "ModuleError"));
    _ = failure.createDataProperty(ctx, v8.String.initUtf8(isolate, "message").name, message);
    _ = run.resolver.deref().reject(ctx, failure.value);
    run.resolver.deinit();
}

fn scopeClose(info: v8.FunctionCallbackInfo) callconv(.c) void {
    var call = Call.init(info);
    call.clear();
    const state = externalPointer(ScopeState, info);
    const id = call.uint(1) catch |err| return call.fail(err);
    const child = childFor(state, id) catch |err| return call.fail(err);
    child.closed = true;
    _ = child.scope.clearImportCache() catch {};
}

// ---- JS callback loader ---------------------------------------------------

/// Reads the module source from a loader result: a string, or an object with an
/// own data property `source` that is a string. Copies into allocator.
fn sourceOf(ctx: v8.Context, isolate: v8.Isolate, value: v8.Value, allocator: std.mem.Allocator) ![]const u8 {
    var source = value;
    if (!value.isString()) {
        const object = value.toObject(ctx) orelse return error.LoaderFailed;
        const descriptor = object.getOwnPropertyDescriptor(ctx, v8.String.initUtf8(isolate, "source").name) orelse return error.LoaderFailed;
        if (!descriptor.isObject()) return error.LoaderFailed;
        source = (descriptor.toObject(ctx) orelse return error.LoaderFailed).get(ctx, str(isolate, "value")) orelse return error.LoaderFailed;
    }
    if (!source.isString()) return error.LoaderFailed;
    const text = source.toString(ctx) orelse return error.LoaderFailed;
    const buffer = try allocator.alloc(u8, text.lenUtf8(isolate));
    return buffer[0..text.writeUtf8(isolate, buffer)];
}

fn jsLoad(data: ?*anyopaque, request: module_types.LoadRequest) anyerror!module_types.LoadResult {
    const loader: *JsLoader = @ptrCast(@alignCast(data.?));
    const host = loader.host;
    const rt = loader.parent.runtime;
    const isolate = rt.isolate;
    const parent_ctx = loader.parent.context.deref();
    parent_ctx.enter();
    defer parent_ctx.exit();
    host.in_loader = true;
    defer host.in_loader = false;
    var tc: v8.TryCatch = undefined;
    tc.init(isolate);
    defer tc.deinit();
    const result = loader.function.deref().call(parent_ctx, v8.Primitive.initUndefined(isolate).value, &.{str(isolate, request.module_id)}) orelse return error.LoaderFailed;
    if (result.isPromise()) {
        const pending = try host.allocator.create(PendingLoad);
        errdefer host.allocator.destroy(pending);
        pending.* = .{ .host = host, .token = request.token };
        const external = v8.External.init(isolate, pending).value.data;
        const on_fulfilled = v8.Function.init(parent_ctx, loadFulfilled, external, 1, .Throw, .HasSideEffect);
        const on_rejected = v8.Function.init(parent_ctx, loadRejected, external, 1, .Throw, .HasSideEffect);
        const promise = v8.Promise.from_opaque(result.data.handle).?;
        _ = promise.then2(parent_ctx, on_fulfilled, on_rejected) orelse return error.LoaderFailed;
        return .pending;
    }
    return .{ .source = try sourceOf(parent_ctx, isolate, result, request.allocator) };
}

fn loadFulfilled(info: v8.FunctionCallbackInfo) callconv(.c) void {
    const pending = externalPointer(PendingLoad, info);
    const host = pending.host;
    defer host.allocator.destroy(pending);
    const isolate = info.isolate();
    const ctx = isolate.getCurrentContext();
    const rt: *Runtime = runtimeOf(ctx) orelse return;
    const source = sourceOf(ctx, isolate, info.get_arg(0), host.allocator) catch {
        rt.completeLoad(pending.token, .{ .failure = error.LoaderFailed }) catch {};
        return;
    };
    defer host.allocator.free(source);
    rt.completeLoad(pending.token, .{ .content = .{ .source = source } }) catch {};
}

fn loadRejected(info: v8.FunctionCallbackInfo) callconv(.c) void {
    const pending = externalPointer(PendingLoad, info);
    defer pending.host.allocator.destroy(pending);
    const ctx = info.isolate().getCurrentContext();
    const rt: *Runtime = runtimeOf(ctx) orelse return;
    rt.completeLoad(pending.token, .{ .failure = error.LoaderRejected }) catch {};
}

/// Finds the Runtime owning `ctx` via the scope pointer in embedder data slot 1.
fn runtimeOf(ctx: v8.Context) ?*Runtime {
    const scope: *Scope = @ptrCast(@alignCast(ctx.getAlignedPointerFromEmbedderData(1) orelse return null));
    return scope.runtime;
}

// ---- init scope resolver and loader --------------------------------------

fn initResolve(data: ?*anyopaque, request: module_types.ResolveRequest) anyerror![]const u8 {
    _ = data;
    const spec = request.specifier;
    if (!(std.mem.startsWith(u8, spec, "./") or std.mem.startsWith(u8, spec, "../"))) return request.allocator.dupe(u8, spec);
    const base = std.fs.path.dirnamePosix(request.referrer) orelse "";
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(request.allocator);
    inline for (.{ base, spec }) |chunk| {
        var it = std.mem.splitScalar(u8, chunk, '/');
        while (it.next()) |part| {
            if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
            if (std.mem.eql(u8, part, "..")) {
                if (parts.items.len == 0) return error.InvalidPath;
                _ = parts.pop();
            } else try parts.append(request.allocator, part);
        }
    }
    return std.mem.join(request.allocator, "/", parts.items);
}

fn initLoad(data: ?*anyopaque, request: module_types.LoadRequest) anyerror!module_types.LoadResult {
    const host: *Host = @ptrCast(@alignCast(data.?));
    if (std.mem.eql(u8, request.module_id, std_io_id)) return .{ .source = std_io_source };
    const source = std.Io.Dir.cwd().readFileAlloc(host.io, request.module_id, request.allocator, .unlimited) catch |err| return err;
    return .{ .source = source };
}
