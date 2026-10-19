//! The shape of an embedded `origine:` module: its id, its JS source and, optionally,
//! the natives its host hands it, with state of the module's own.
//!
//! Each `std_*.zig` returns its modules from a `modules()` function and
//! `origine_modules.zig` concatenates them. A module's natives come in two flavours:
//!
//! - `stateless(table)`: natives take the scope's `*ScopeState` (errno cell, host).
//! - `stateful(S, table)`: the module owns one `S` per scope, created the first time the
//!   module reads `import.meta`, and natives take `*Cell(S)` (the `S` is `cell.data`, the
//!   scope's state is `cell.scope`). `S` may declare `init(scope: *ScopeState) !S` (default:
//!   `S{}`) and `deinit(self: *S) void`; it is torn down in `Host.destroy`, before
//!   `Runtime.destroy`, so it may own V8 persistent handles.
const std = @import("std");
const v8 = @import("@v8");
const binding = @import("binding.zig");
pub const ScopeState = @import("host.zig").ScopeState;

/// A module served from memory.
pub const Module = struct {
    /// Canonical module id, `origine:...`. Static storage.
    id: []const u8,
    /// ES module source. Static storage, valid for the whole run.
    source: []const u8,
    /// How to build this module's natives; they are delivered as `import.meta.native` to
    /// this module only. Null for pure-JS modules.
    bindings: ?Bindings = null,
};

/// Type-erased lifecycle of a module's per-scope state and natives. Built by `stateless`
/// or `stateful`; the host calls `create` at most once per scope, `build` with the
/// result, and `destroy` at `Host.destroy`.
pub const Bindings = struct {
    /// Creates the state for `scope`. The result is owned by the scope's state record
    /// until `destroy`.
    create: *const fn (scope: *ScopeState) anyerror!*anyopaque,
    /// Releases what `create` made. Never fails; the scope's V8 handles are still live.
    destroy: *const fn (scope: *ScopeState, state: *anyopaque) void,
    /// Builds the natives object in the entered context. Needs a live HandleScope; returns
    /// a local handle. `state` is `create`'s result for this scope.
    build: *const fn (env: binding.Env, scope: *ScopeState, state: *anyopaque) anyerror!v8.Object,
};

/// A module's per-scope state `S` plus the scope it belongs to; the `State` natives of a
/// `stateful` module are bound to (it provides the binding State protocol).
pub fn Cell(comptime S: type) type {
    return struct {
        scope: *ScopeState,
        data: S,

        pub fn errnoCell(self: *@This()) *u32 {
            return self.scope.errnoCell();
        }
        pub fn allocator(self: *@This()) std.mem.Allocator {
            return self.scope.allocator();
        }
    };
}

/// Natives that need no state of their own: `table` is a `binding.object` table whose
/// functions are wrapped with `binding.func` and take `*ScopeState` first.
pub fn stateless(comptime table: anytype) Bindings {
    return .{
        .create = struct {
            fn create(scope: *ScopeState) anyerror!*anyopaque {
                return scope;
            }
        }.create,
        .destroy = struct {
            fn destroy(_: *ScopeState, _: *anyopaque) void {}
        }.destroy,
        .build = struct {
            fn build(env: binding.Env, scope: *ScopeState, _: *anyopaque) anyerror!v8.Object {
                return binding.object(env, ScopeState, scope, table);
            }
        }.build,
    };
}

/// Natives with per-scope state `S`: `table`'s functions (wrapped with `binding.func`) take `*Cell(S)` first.
pub fn stateful(comptime S: type, comptime table: anytype) Bindings {
    const C = Cell(S);
    return .{
        .create = struct {
            fn create(scope: *ScopeState) anyerror!*anyopaque {
                const alloc = scope.allocator();
                const cell = try alloc.create(C);
                errdefer alloc.destroy(cell);
                cell.* = .{ .scope = scope, .data = if (@hasDecl(S, "init")) try S.init(scope) else .{} };
                return cell;
            }
        }.create,
        .destroy = struct {
            fn destroy(scope: *ScopeState, state: *anyopaque) void {
                const cell: *C = @ptrCast(@alignCast(state));
                if (@hasDecl(S, "deinit")) cell.data.deinit();
                scope.allocator().destroy(cell);
            }
        }.destroy,
        .build = struct {
            fn build(env: binding.Env, _: *ScopeState, state: *anyopaque) anyerror!v8.Object {
                const cell: *C = @ptrCast(@alignCast(state));
                return binding.object(env, C, cell, table);
            }
        }.build,
    };
}
