//! The REPL's parsing and line editor, which live in Rust (rust/crates/origine_repl): dot-commands,
//! pending multiline source, history, TypeScript/await/import preparation and the readline-style
//! editor. This is the thin Zig view of its C ABI. Nothing here touches the terminal or V8.
const std = @import("std");
const abi = @import("repl_abi.zig");

pub const Host = abi.Host;
pub const Sink = abi.Sink;
pub const push = abi.origine_repl_sink_push;

pub const Command = union(enum) {
    /// Not a command: source.
    source,
    help,
    exit,
    clear,
    history,
    /// `.again [number]`: one-based history entry, latest when null.
    again: ?usize,
    /// `.complete [prefix]`; borrows the engine until its next call.
    complete: []const u8,
    invalid,
};

pub const Prepared = enum { script, async, incomplete, @"error" };
pub const Edit = enum { @"continue", line, eof, canceled };

pub const Engine = struct {
    handle: *abi.Repl,

    pub fn init(colors: bool) error{OutOfMemory}!Engine {
        return .{ .handle = abi.origine_repl_new(colors) orelse return error.OutOfMemory };
    }

    pub fn deinit(self: Engine) void {
        abi.origine_repl_free(self.handle);
    }

    /// Text kept by the engine; valid until its next call.
    pub fn buffer(self: Engine, which: abi.Buffer) []const u8 {
        var len: usize = 0;
        const ptr = abi.origine_repl_buffer(self.handle, @backingInt(which), &len) orelse return "";
        return ptr[0..len];
    }

    /// Pending (multiline) source.
    pub fn source(self: Engine) []const u8 {
        return self.buffer(.source);
    }

    pub fn command(self: Engine, line: []const u8) Command {
        var number: usize = 0;
        const kind: abi.Command = @fromBackingInt(@intCast(abi.origine_repl_command(self.handle, line.ptr, line.len, &number)));
        return switch (kind) {
            .source => .source,
            .help => .help,
            .exit => .exit,
            .clear => .clear,
            .history => .history,
            .again => .{ .again = if (number == 0) null else number },
            .complete => .{ .complete = self.buffer(.argument) },
            .invalid => .invalid,
        };
    }

    /// Adds a line to the pending source. error.InputTooLong when it would pass 64 KiB.
    pub fn append(self: Engine, line: []const u8) error{InputTooLong}!void {
        if (abi.origine_repl_append(self.handle, line.ptr, line.len) == abi.append_too_long) return error.InputTooLong;
    }

    pub fn clear(self: Engine) void {
        abi.origine_repl_clear(self.handle);
    }

    /// Stores the pending source in the history (consecutive duplicates once).
    pub fn remember(self: Engine) void {
        abi.origine_repl_remember(self.handle);
    }

    /// Replaces the pending source by a one-based history entry (null: the latest).
    pub fn recall(self: Engine, number: ?usize) error{NoHistoryEntry}!void {
        if (!abi.origine_repl_recall(self.handle, number orelse 0)) return error.NoHistoryEntry;
    }

    pub fn historyLen(self: Engine) usize {
        return abi.origine_repl_history_len(self.handle);
    }

    pub fn historyEntry(self: Engine, index: usize) []const u8 {
        var len: usize = 0;
        const ptr = abi.origine_repl_history_get(self.handle, index, &len) orelse return "";
        return ptr[0..len];
    }

    /// Parses the pending source. Details: `.code` (what to run), `.plain` (the JavaScript before
    /// the async rewrite), `.diagnostics`.
    pub fn prepare(self: Engine) Prepared {
        const kind: abi.Prepared = @fromBackingInt(@intCast(abi.origine_repl_prepare(self.handle)));
        return switch (kind) {
            .script => .script,
            .async => .async,
            .incomplete => .incomplete,
            .@"error" => .@"error",
        };
    }

    pub fn editBegin(self: Engine, prompt: []const u8) void {
        abi.origine_repl_edit_begin(self.handle, prompt.ptr, prompt.len);
    }

    pub fn editFeed(self: Engine, byte: u8, width: u32, host: *const Host) Edit {
        return @fromBackingInt(@intCast(abi.origine_repl_edit_feed(self.handle, byte, width, host)));
    }

    pub fn editTimeout(self: Engine, width: u32, host: *const Host) Edit {
        return @fromBackingInt(@intCast(abi.origine_repl_edit_timeout(self.handle, width, host)));
    }

    pub fn editEof(self: Engine) Edit {
        return @fromBackingInt(@intCast(abi.origine_repl_edit_eof(self.handle)));
    }

    /// Inside an escape sequence: the next read should give up after a few milliseconds.
    pub fn inSequence(self: Engine) bool {
        return abi.origine_repl_edit_in_sequence(self.handle);
    }
};
