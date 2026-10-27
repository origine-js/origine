//! The interactive/piped read-eval-print loop. A Session borrows the scope, I/O
//! runtime and platform for its whole run and owns its helpers and the Rust engine (pending
//! input, history, parsing and line editor); everything is released when `run` returns.
const std = @import("std");
const v8 = @import("@v8");
const m = @import("@managed");
const eu = @import("@util");
const eval_mod = @import("eval.zig");
const display = @import("display.zig");
const tty = @import("tty.zig");
const Helpers = @import("helpers.zig").Helpers;
const Engine = @import("engine.zig").Engine;

const max_source = 64 * 1024;

pub const Options = struct {
    allocator: std.mem.Allocator,
    platform: v8.Platform,
    /// Line editing with prompts; false reads plain lines from stdin.
    interactive: bool,
    /// ANSI colors for results, errors and highlighting.
    colors: bool,
    /// Drives `api.io` work while awaiting; null awaits platform tasks and microtasks only.
    host: ?*m.Api.Host = null,
};

const help_text =
    \\.help                 show commands
    \\.exit                 exit (also exit() or Ctrl+D)
    \\.clear / .break       discard pending multiline input
    \\.history              list the last 100 evaluations in this session
    \\.again [number]       evaluate a history entry (default: latest)
    \\.complete [prefix]    list global/property names, e.g. Math.ma
    \\Tab                   complete the name at the cursor (interactive)
    \\Right / End           accept the inline suggestion
    \\Up / Down             browse history; Down restores your draft
    \\_ / _error            last result / last thrown value
    \\await / import       top-level await and `import ... from` work; `api` is the host API
    \\
;

/// What one line of input asks the loop to do next.
const Step = enum { skip, evaluate, quit };

const Line = union(enum) {
    text: []const u8,
    eof,
    canceled,
};

const Session = struct {
    scope: *m.Scope,
    options: Options,
    helpers: Helpers,
    engine: Engine,
    reader: m.sys.File.Reader,

    fn print(_: *Session, comptime format: []const u8, args: anytype) void {
        display.print(format, args);
    }

    fn prompt(self: *const Session) []const u8 {
        return if (self.engine.source().len == 0) "> " else "... ";
    }

    /// The returned text is valid until the next read.
    fn readLine(self: *Session) !Line {
        if (self.options.interactive) {
            const line = tty.readLine(self.engine, self.options.allocator, self.prompt(), &self.helpers) catch |err| switch (err) {
                error.Canceled => return .canceled,
                else => return err,
            };
            return if (line) |text| .{ .text = text } else .eof;
        }
        const line = self.reader.interface.takeDelimiter('\n') catch |err| {
            self.print("Input error: {s}\n", .{@errorName(err)});
            return .eof;
        };
        return if (line) |text| .{ .text = text } else .eof;
    }

    /// Interprets one line: dot-commands act immediately, anything else joins
    /// the pending source and is evaluated once it compiles as complete input.
    fn step(self: *Session, line: []const u8) !Step {
        switch (self.engine.command(line)) {
            .exit => return .quit,
            .help => self.print(help_text, .{}),
            .clear => self.engine.clear(),
            .history => for (0..self.engine.historyLen()) |index| self.print("{d}: {s}\n", .{ index + 1, self.engine.historyEntry(index) }),
            .again => |number| {
                if (self.engine.source().len != 0) {
                    self.print("Use .clear before recalling history.\n", .{});
                    return .skip;
                }
                self.engine.recall(number) catch {
                    self.print("No such history entry.\n", .{});
                    return .skip;
                };
                return .evaluate;
            },
            .complete => |prefix| {
                const matches = self.helpers.complete(prefix) catch {
                    self.print("Completion failed.\n", .{});
                    return .skip;
                };
                defer matches.deinit();
                display.show(self.scope, matches);
            },
            .invalid => self.print("Unknown command or invalid arguments; use .help.\n", .{}),
            .source => {
                const trimmed = std.mem.trim(u8, line, " \r\t");
                if (self.engine.source().len == 0) {
                    if (trimmed.len == 0) return .skip;
                    if (std.mem.eql(u8, trimmed, "exit()")) return .quit;
                }
                self.engine.append(line) catch |err| {
                    if (err != error.InputTooLong) return err;
                    self.print("Input exceeds 64 KiB; pending input discarded.\n", .{});
                    self.engine.clear();
                    return .skip;
                };
                // The engine decides whether the input stops mid-construct (types included).
                return if (self.engine.prepare() == .incomplete) .skip else .evaluate;
            },
        }
        return .skip;
    }

    /// Evaluates the pending source, prints the outcome and clears the input.
    /// Releases every result handle before returning, then drains platform tasks.
    fn evaluate(self: *Session) !void {
        defer self.engine.clear();
        self.engine.remember();
        self.evaluateSource();
        self.scope.runtime.pumpPlatform(self.options.platform);
    }

    fn evaluateSource(self: *Session) void {
        const colors = self.options.colors;
        const prepared = self.engine.prepare();
        switch (prepared) {
            // Unfinished input at end of input is diagnosed like any other syntax error.
            .incomplete, .@"error" => {
                if (colors) self.print("\x1b[31m", .{});
                self.print("{s}\n", .{std.mem.trimEnd(u8, self.engine.buffer(.diagnostics), "\n")});
                if (colors) self.print("\x1b[0m", .{});
                return;
            },
            .script, .async => {},
        }
        // Both buffers stay valid: nothing below calls the engine again.
        const source = self.engine.buffer(.code);
        const typed = self.engine.buffer(.plain);
        var error_info: m.ErrorInfo = .{};
        defer error_info.deinit();
        const result = self.run(source, prepared == .async, &error_info) catch |err| {
            if (error_info.exception) |value| {
                self.helpers.remember(typed, value, true) catch {};
                if (colors) self.print("\x1b[31m", .{});
                display.show(self.scope, value);
                if (colors) self.print("\x1b[0m", .{});
            } else if (err == error.Stalled) {
                self.print("Promise never settled: nothing left that could resolve it.\n", .{});
            } else self.print("Evaluation failed: {s}\n", .{@errorName(err)});
            return;
        };
        defer result.deinit();
        self.helpers.remember(typed, result, false) catch {};
        const formatted = self.helpers.display(if (colors) "inspectColor" else "inspect", result) catch {
            self.print("<value inspection failed>\n", .{});
            return;
        };
        defer formatted.deinit();
        display.show(self.scope, formatted);
    }

    /// Evaluates `source`; code that was rewritten for top-level `await` or static `import` is an
    /// async function call whose promise is awaited. A rejection surfaces as a thrown value.
    fn run(self: *Session, source: []const u8, asynchronous: bool, error_info: *m.ErrorInfo) !v8.Global.Of(v8.Value) {
        if (!asynchronous) return eval_mod.eval(self.scope, source, error_info);
        const pending = try self.scope.eval(source, eval_mod.origin, error_info);
        defer pending.deinit();
        return self.settle(pending, error_info);
    }

    /// Drives the runtime until the async function's promise settles; returns its value.
    fn settle(self: *Session, value: v8.Global.Of(v8.Value), error_info: *m.ErrorInfo) !v8.Global.Of(v8.Value) {
        const rt = self.scope.runtime;
        const promise: v8.Global.Of(v8.Promise) = blk: {
            var session: m.Scope.Session = undefined;
            session.init(self.scope);
            defer session.deinit();
            const local = v8.Promise.from_opaque(value.deref().data.handle) orelse return error.JavaScriptException;
            local.markAsHandled();
            break :blk .new(session.isolate(), local);
        };
        defer promise.deinit();
        if (self.options.host) |host| {
            try host.settle(rt, self.options.platform, promise);
        } else while (true) {
            rt.pumpPlatform(self.options.platform);
            var session: m.Runtime.Session = undefined;
            session.init(rt);
            defer session.deinit();
            if (promise.deref().state() != .Pending) break;
            if (!self.options.platform.pumpMessageLoop(rt.isolate, false)) return error.Stalled;
        }
        var session: m.Scope.Session = undefined;
        session.init(self.scope);
        defer session.deinit();
        const outcome = promise.deref();
        if (outcome.state() == .Rejected) {
            error_info.deinit();
            error_info.exception = .new(session.isolate(), outcome.result());
            return error.JavaScriptException;
        }
        return .new(session.isolate(), outcome.result());
    }

    /// Exposes the host API as the global `api`, as init modules receive it in `main(api)`.
    fn installApi(self: *Session, host: *m.Api.Host) !void {
        const api = try host.install(self.scope, null);
        defer api.deinit();
        var session: m.Scope.Session = undefined;
        session.init(self.scope);
        defer session.deinit();
        const key = eu.v.str_utf8(session.isolate(), "api").name.primitive.value;
        _ = session.ctx.getGlobal().set(session.ctx, key, api.deref()) orelse return error.JavaScriptException;
    }

    fn loop(self: *Session) !void {
        while (true) {
            const line = switch (try self.readLine()) {
                .text => |text| text,
                .canceled => {
                    self.engine.clear();
                    continue;
                },
                .eof => {
                    // EOF must diagnose incomplete input rather than silently dropping it.
                    if (self.engine.source().len != 0) try self.evaluate();
                    return;
                },
            };
            switch (try self.step(line)) {
                .skip => {},
                .evaluate => try self.evaluate(),
                .quit => return,
            }
        }
    }
};

/// Runs the REPL until exit, EOF or an unrecoverable host error.
pub fn run(scope: *m.Scope, options: Options) !void {
    const helpers = try Helpers.init(scope);
    defer helpers.deinit();
    const buffer = try options.allocator.alloc(u8, max_source + 1);
    defer options.allocator.free(buffer);
    const engine = try Engine.init(options.colors);
    defer engine.deinit();
    var session: Session = .{
        .scope = scope,
        .options = options,
        .helpers = helpers,
        .engine = engine,
        .reader = m.sys.File.stdin().reader(buffer),
    };
    if (options.host) |host| try session.installApi(host);
    try session.loop();
}
