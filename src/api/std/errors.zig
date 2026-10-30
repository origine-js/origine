//! Error classes shared with the API glue in this realm.
const v8 = @import("@v8");
const binding = @import("../binding.zig");
const mod = @import("../module.zig");
const glue = @import("../glue.zig");

pub fn modules() [1]mod.Module {
    const bindings: mod.Bindings = .{
        .create = struct {
            fn f(scope: *mod.ScopeState) anyerror!*anyopaque {
                return scope;
            }
        }.f,
        .release = struct {
            fn f(_: *mod.ScopeState, _: *anyopaque) void {}
        }.f,
        .destroy = struct {
            fn f(_: *mod.ScopeState, _: *anyopaque) void {}
        }.f,
        .build = build,
    };
    return .{.{ .id = "origine:@std/errors", .source = @embedFile("../../js/std/errors.js"), .bindings = bindings }};
}
fn build(env: binding.Env, _: *mod.ScopeState, _: *anyopaque) anyerror!v8.Object {
    try glue.prepare(env.isolate, env.ctx);
    const bundle = glue.restored(env.ctx).?;
    const classes = bundle.object.getIndex(env.ctx, glue.errors_index) orelse return error.BootstrapFailed;
    const out = @import("@util").v.object(env.isolate);
    try binding.set(env, out, "classes", classes);
    return out;
}
