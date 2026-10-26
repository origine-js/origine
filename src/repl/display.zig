//! Host-side printing shared by the REPL and the init runner. Borrows the I/O
//! runtime for each call; retains nothing.
const std = @import("std");
const v8 = @import("@v8");
const eu = @import("@util");
const m = @import("@managed");

/// Buffered stdout write; I/O errors are dropped because there is nowhere to report them.
pub fn print(io: std.Io, comptime format: []const u8, args: anytype) void {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io, &buffer);
    writer.interface.print(format, args) catch return;
    writer.interface.flush() catch return;
}

/// Prints `value` as text, preferring an Error's `stack` (diagnostics from the
/// TypeScript transformer put their file:line:col lines there). Local V8 handles
/// and UTF-8 storage are released before return.
pub fn show(io: std.Io, scope: *m.Scope, value: v8.Global.Of(v8.Value)) void {
    var session: m.Scope.Session = undefined;
    session.init(scope);
    defer session.deinit();
    const isolate = session.isolate();
    // toString may invoke arbitrary guest code, including a throwing getter; the
    // session's TryCatch contains it.
    var shown = value.deref();
    if (shown.toObject(session.ctx)) |object| {
        if (object.get(session.ctx, eu.v.str_utf8(isolate, "stack").name.primitive.value)) |stack| {
            if (stack.isString()) shown = stack;
        }
    }
    const text = shown.toString(session.ctx) orelse {
        print(io, "<value conversion threw>\n", .{});
        return;
    };
    const buffer = eu.alloc.alloc(u8, text.lenUtf8(isolate)) catch return;
    defer eu.alloc.free(buffer);
    const length = text.writeUtf8(isolate, buffer);
    print(io, "{s}\n", .{buffer[0..length]});
}
