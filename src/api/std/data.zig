//! `origine:@std/data`: `snapshot` copies plain data and `deepFreeze` freezes a graph of it in place. The natives hold no
//! authority and touch only the values they are given: `isProxy` (a Proxy cannot be told apart in JS) and `deepFreeze`
//! (the realm's own hardener, the one preload values use: plain data and functions are frozen in place with what they
//! reach; anything else, such as a Map, a typed array, a promise, a proxy or an accessor, is refused).
const v8 = @import("@v8");
const binding = @import("../binding.zig");
const module = @import("../module.zig");

pub fn modules() [1]module.Module {
    const natives = struct {
        pub fn isProxy(state: *module.ScopeState, value: v8.Value) bool {
            _ = state;
            return value.isProxy();
        }

        /// Deep-freezes `value` in place with the realm's hardener. False when it reaches something the hardener
        /// refuses (the graph may be partly frozen then: freezing is not transactional).
        pub fn deepFreeze(state: *module.ScopeState, value: v8.Value) bool {
            var catcher: v8.TryCatch = undefined;
            catcher.init(state.scope.runtime.isolate);
            defer catcher.deinit();
            state.scope.hardenLocal(value) catch return false;
            return true;
        }
    };
    return .{.{
        .id = "origine:@std/data",
        .source = @embedFile("../../js/std/data.js"),
        .bindings = module.stateless(.{
            .isProxy = binding.func(natives.isProxy, .{ .side_effect = .none }),
            .deepFreeze = binding.func(natives.deepFreeze, .{ .side_effect = .any }),
        }),
    }};
}
