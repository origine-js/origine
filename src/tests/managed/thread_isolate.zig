const std = @import("std");
const t = std.testing;
const v8 = @import("@v8");
const m = @import("@managed");
const support = @import("../support.zig");
const ensureV8 = support.ensureV8;

const Isolate = m.Api.ThreadIsolate;
const Outcome = @import("std").meta.fieldInfo(Isolate, .outcome).type;

/// A tmp dir holding `init.js`; `spawn` starts a thread isolate on it with the dir as fs root.
const Fixture = struct {
    tmp: t.TmpDir,
    init_path: []u8,
    buffers: v8.ArrayBuffer.Allocator,

    fn setup(self: *Fixture, source: []const u8) !void {
        ensureV8();
        self.tmp = t.tmpDir(.{ .iterate = true });
        errdefer self.tmp.cleanup();
        try self.tmp.dir.writeFile(t.io, .{ .sub_path = "init.js", .data = source });
        self.init_path = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}/init.js", .{self.tmp.sub_path});
        errdefer t.allocator.free(self.init_path);
        // As the process entry point: a sandboxed V8 only accepts ArrayBuffer memory from its own pages.
        self.buffers = if (v8.V8.isSandboxEnabled())
            try v8.ArrayBuffer.Allocator.fromSandbox()
        else
            try v8.ArrayBuffer.Allocator.fromZig(t.allocator);
    }

    fn spawn(self: *Fixture, args: []const []const u8) !*Isolate {
        return Isolate.spawn(t.allocator, .{
            .init = self.init_path,
            .args = args,
            .env = &.{.{ .name = "HOME", .value = "/home/child" }},
            .fs = .{ .root = .{ .handle = self.tmp.dir.handle } },
            .array_buffer_allocator = self.buffers,
            .platform = support.engine.platform,
        });
    }

    fn readFile(self: *Fixture, name: []const u8) ![]u8 {
        return self.tmp.dir.readFileAlloc(t.io, name, t.allocator, .limited(4096));
    }

    fn deinit(self: *Fixture) void {
        self.buffers.deinit();
        t.allocator.free(self.init_path);
        self.tmp.cleanup();
    }
};

test "thread isolate: runs init and main on its own thread with copied args and env" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { Dir, IoError } from 'origine:@std/io';
        \\export function main(api) {
        \\  const sync = api.fs.requestSync({ access: 'rw' });
        \\  const f = IoError.check(sync, sync.dirOpenFile(Dir.cwd(), 'out.txt', 'w'));
        \\  const text = api.host.env.args().join(',') + '|' + api.host.env.get('HOME');
        \\  sync.fileWriteAll(f, Uint8Array.from(text, c => c.charCodeAt(0)));
        \\  sync.fileClose(f);
        \\}
    );
    defer fx.deinit();
    const child = try fx.spawn(&.{ fx.init_path, "a", "b" });
    defer child.destroy();
    const outcome = child.join();
    if (child.failure()) |name| std.debug.print("child failed: {s}\n", .{name});
    try t.expectEqual(.completed, outcome);
    const text = try fx.readFile("out.txt");
    defer t.allocator.free(text);
    try t.expect(std.mem.endsWith(u8, text, ",a,b|/home/child"));
}

test "thread isolate: terminate interrupts a running main" {
    var fx: Fixture = undefined;
    try fx.setup("export function main() { for (;;) {} }");
    defer fx.deinit();
    const child = try fx.spawn(&.{});
    defer child.destroy();
    // Give the thread time to enter the loop; terminate also works before it does.
    var delay: std.c.timespec = .{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
    _ = std.c.nanosleep(&delay, null);
    child.terminate();
    try t.expectEqual(.terminated, child.join());
}

test "thread isolate: a throwing main reports failed" {
    var fx: Fixture = undefined;
    try fx.setup("export function main() { throw new Error('boom'); }");
    defer fx.deinit();
    const child = try fx.spawn(&.{});
    defer child.destroy();
    try t.expectEqual(.failed, child.join());
    try t.expectEqualStrings("MainFailed", child.failure().?);
}

test "thread isolate: several isolates run at once and join" {
    var fx: Fixture = undefined;
    try fx.setup("export async function main() { await Promise.resolve(); }");
    defer fx.deinit();
    var children: [4]*Isolate = undefined;
    for (&children) |*child| child.* = try fx.spawn(&.{});
    // Join every thread before checking: a failed expectation must not free what a thread still uses.
    var outcomes: [children.len]Outcome = undefined;
    for (children, &outcomes) |child, *out| out.* = child.join();
    for (children, outcomes) |child, outcome| {
        defer child.destroy();
        if (child.failure()) |name| std.debug.print("child failed: {s}\n", .{name});
        try t.expectEqual(.completed, outcome);
    }
}
