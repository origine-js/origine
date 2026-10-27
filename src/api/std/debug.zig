//! `origine:@std/debug`: the program's only output without a capability, one line on the
//! process's standard error. The native takes the finished line; the JS wrapper converts
//! and joins the values, so the call site sees `String()` semantics.
const binding = @import("../binding.zig");
const module = @import("../module.zig");
const stderr = @import("../../managed/stderr.zig");

pub fn modules() [1]module.Module {
    const natives = struct {
        /// Writes `line` and a newline to stderr. Write errors are dropped, like `std.debug.print`.
        pub fn write(state: *module.ScopeState, line: []const u8) void {
            _ = state;
            stderr.print("{s}\n", .{line});
        }
    };
    return .{.{
        .id = "origine:@std/debug",
        .source = @embedFile("../../js/std/debug.js"),
        .bindings = module.stateless(.{
            .write = binding.func(natives.write, .{ .side_effect = .any }),
        }),
    }};
}
