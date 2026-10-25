//! The interactive/piped read-eval-print loop. A Session borrows the scope, I/O
//! runtime and platform for its whole run and owns its helpers, pending input,
//! history and line editor; everything is released when `run` returns.
const std = @import("std");
const v8 = @import("@v8");
const m = @import("@managed");
const eval_mod = @import("eval.zig");
const display = @import("display.zig");
const Helpers = @import("helpers.zig").Helpers;
const Input = @import("input.zig").Input;
const input_mod = @import("input.zig");
const Editor = @import("terminal.zig").Editor;

pub const Options = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    platform: v8.Platform,
    /// Line editing with prompts; false reads plain lines from stdin.
    interactive: bool,
    /// ANSI colors for results, errors and highlighting.
    colors: bool,
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
    input: Input,
    editor: Editor,
    reader: std.Io.File.Reader,

    fn print(self: *Session, comptime format: []const u8, args: anytype) void {
        display.print(self.options.io, format, args);
    }

    fn prompt(self: *const Session) []const u8 {
        return if (self.input.source.items.len == 0) "> " else "... ";
    }

    /// The returned text is valid until the next read.
    fn readLine(self: *Session) !Line {
        if (self.options.interactive) {
            const line = self.editor.read(self.prompt(), self.helpers, &self.input) catch |err| switch (err) {
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
        switch (input_mod.command(line)) {
            .exit => return .quit,
            .help => self.print(help_text, .{}),
            .clear => self.input.clear(),
            .history => for (self.input.history.items, 1..) |entry, n| self.print("{d}: {s}\n", .{ n, entry }),
            .again => |number| {
                if (self.input.source.items.len != 0) {
                    self.print("Use .clear before recalling history.\n", .{});
                    return .skip;
                }
                self.input.recall(number) catch {
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
                display.show(self.options.io, self.scope, matches);
            },
            .invalid => self.print("Unknown command or invalid arguments; use .help.\n", .{}),
            .source => {
                const trimmed = std.mem.trim(u8, line, " \r\t");
                if (self.input.source.items.len == 0) {
                    if (trimmed.len == 0) return .skip;
                    if (std.mem.eql(u8, trimmed, "exit()")) return .quit;
                }
                self.input.append(line) catch |err| {
                    if (err != error.InputTooLong) return err;
                    self.print("Input exceeds 64 KiB; pending input discarded.\n", .{});
                    self.input.clear();
                    return .skip;
                };
                return if (eval_mod.incomplete(self.scope, self.input.source.items)) .skip else .evaluate;
            },
        }
        return .skip;
    }

    /// Evaluates the pending source, prints the outcome and clears the input.
    /// Releases every result handle before returning, then drains platform tasks.
    fn evaluate(self: *Session) !void {
        defer self.input.clear();
        try self.input.remember();
        self.evaluateSource(self.input.source.items);
        self.scope.runtime.pumpPlatform(self.options.platform);
    }

    fn evaluateSource(self: *Session, source: []const u8) void {
        const colors = self.options.colors;
        var error_info: m.ErrorInfo = .{};
        defer error_info.deinit();
        const result = eval_mod.eval(self.scope, source, &error_info) catch |err| {
            if (error_info.exception) |value| {
                self.helpers.remember(source, value, true) catch {};
                if (colors) self.print("\x1b[31m", .{});
                display.show(self.options.io, self.scope, value);
                if (colors) self.print("\x1b[0m", .{});
            } else self.print("Evaluation failed: {s}\n", .{@errorName(err)});
            return;
        };
        defer result.deinit();
        self.helpers.remember(source, result, false) catch {};
        const formatted = self.helpers.display(if (colors) "inspectColor" else "inspect", result) catch {
            self.print("<value inspection failed>\n", .{});
            return;
        };
        defer formatted.deinit();
        display.show(self.options.io, self.scope, formatted);
    }

    fn loop(self: *Session) !void {
        while (true) {
            const line = switch (try self.readLine()) {
                .text => |text| text,
                .canceled => {
                    self.input.clear();
                    continue;
                },
                .eof => {
                    // EOF must diagnose incomplete input rather than silently dropping it.
                    if (self.input.source.items.len != 0) try self.evaluate();
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
    const buffer = try options.allocator.alloc(u8, Input.max_source + 1);
    defer options.allocator.free(buffer);
    var session: Session = .{
        .scope = scope,
        .options = options,
        .helpers = helpers,
        .input = Input.init(options.allocator),
        .editor = .{ .allocator = options.allocator, .colors = options.colors },
        .reader = std.Io.File.stdin().reader(options.io, buffer),
    };
    defer session.input.deinit();
    defer session.editor.deinit();
    try session.loop();
}
