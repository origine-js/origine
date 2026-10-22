//! TEMP(debug): minimal host-backed JavaScript `print()` binding; remove this
//! module and its Scope.create call when the debugging hook is no longer needed.
const std = @import("std");
const v8 = @import("@v8");
const eu = @import("@util");

/// Installs a read-only global `print` in ctx. Borrows ctx through return and
/// retains no host resources; reports JavaScript property installation failures.
pub fn install(isolate: v8.Isolate, ctx: v8.Context) !void {
    const function = v8.Function.init(ctx, callback, null, 0, .Throw, .HasSideEffect);
    const key = eu.v.str_utf8(isolate, "print").name;
    const installed = ctx.getGlobal().defineOwnProperty(ctx, key, function.object.value, .{ .ReadOnly = true, .DontDelete = true }) orelse return error.JavaScriptException;
    if (!installed) return error.PrintInstallationFailed;
}

/// Converts each argument to a string and writes a space-separated line to stderr.
/// Borrows callback handles through return, allocates conversion buffers from the
/// process page allocator, and releases them before returning. A failed conversion
/// propagates its JavaScript exception; allocation failures discard the call.
pub fn callback(info: v8.FunctionCallbackInfo) callconv(.c) void {
    const isolate = info.isolate();
    const ctx = isolate.getCurrentContext();
    const alloc = std.heap.page_allocator;
    for (0..@intCast(info.length())) |index| {
        if (index != 0) std.debug.print(" ", .{});
        const text = info.get_arg(@intCast(index)).toString(ctx) orelse return;
        const buffer = alloc.alloc(u8, text.lenUtf8(isolate)) catch return;
        defer alloc.free(buffer);
        const length = text.writeUtf8(isolate, buffer);
        std.debug.print("{s}", .{buffer[0..length]});
    }
    std.debug.print("\n", .{});
}
