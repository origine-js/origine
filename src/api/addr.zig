//! `native.addr`: the parsers behind `IpAddr.parse` and `SocketAddr.parse` (src/js/glue/addr.js). They hold no
//! authority and need no scope resource, so they keep working in a disposed scope. A parse writes into an
//! out buffer the caller made, and the caller's `IpAddr` and `SocketAddr` keep views of that very buffer:
//!
//!     bytes 0..16   the octets (4 used for IPv4, 16 for IPv6)
//!     bytes 16..18  the port, a native-endian u16 (`parseSocket` only)
//!
//! The result is the family (4 or 6), or 0 for text that is no address. Invalid text is an ordinary result,
//! not an error, so the errno cell is never touched; the glue builds the `TypeError`. The rules are Rust's
//! `FromStr` for `Ipv4Addr`, `Ipv6Addr` and `SocketAddr` (no zone, no whitespace, no leading zeros in an octet,
//! leading zeros allowed in a port).
const std = @import("std");
const builtin = @import("builtin");
const v8 = @import("@v8");
const binding = @import("binding.zig");
const ScopeCore = @import("host.zig").ScopeCore;

pub const ip_len = 16;
pub const socket_len = 18;
/// `[ffff:ffff:ffff:ffff:ffff:ffff:255.255.255.255]:65535` is the longest address text (53 bytes).
const max_text = 64;

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// A decimal octet: 1 to 3 digits, no leading zero unless it is `0` itself, at most 255.
fn octet(text: []const u8) ?u8 {
    if (text.len == 0 or text.len > 3 or (text.len > 1 and text[0] == '0')) return null;
    var value: u16 = 0;
    for (text) |c| {
        if (!isDigit(c)) return null;
        value = value * 10 + (c - '0');
    }
    return if (value > 255) null else @intCast(value);
}

fn parseV4(text: []const u8, out: *[4]u8) bool {
    var parts = std.mem.splitScalar(u8, text, '.');
    for (out) |*byte| byte.* = octet(parts.next() orelse return false) orelse return false;
    return parts.next() == null;
}

/// `part` is colon-separated groups of 1 to 4 hex digits (empty is zero groups). Null when malformed or more than 8.
fn groups(part: []const u8, out: *[8]u16) ?usize {
    if (part.len == 0) return 0;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, part, ':');
    while (it.next()) |group| {
        if (count == out.len or group.len == 0 or group.len > 4) return null;
        var value: u16 = 0;
        for (group) |c| value = (value << 4) | (std.fmt.charToDigit(c, 16) catch return null);
        out[count] = value;
        count += 1;
    }
    return count;
}

fn parseV6(text: []const u8, out: *[16]u8) bool {
    if (std.mem.indexOf(u8, text, ":::") != null) return false;
    var body = text;
    var tail: [2]u16 = undefined;
    var tail_len: usize = 0;
    // An embedded IPv4 tail (`::ffff:1.2.3.4`) is the last two groups.
    if (std.mem.indexOfScalar(u8, text, '.') != null) {
        const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return false;
        var v4: [4]u8 = undefined;
        if (!parseV4(text[colon + 1 ..], &v4)) return false;
        tail = .{ std.mem.readInt(u16, v4[0..2], .big), std.mem.readInt(u16, v4[2..4], .big) };
        tail_len = 2;
        body = text[0 .. colon + 1];
        if (!std.mem.endsWith(u8, body, "::")) body = body[0 .. body.len - 1];
    }
    var head: [8]u16 = undefined;
    var rest: [8]u16 = undefined;
    var head_len: usize = undefined;
    var rest_len: usize = 0;
    var fill: usize = 0;
    if (std.mem.indexOf(u8, body, "::")) |at| {
        const after = body[at + 2 ..];
        if (std.mem.indexOf(u8, after, "::") != null) return false;
        head_len = groups(body[0..at], &head) orelse return false;
        rest_len = groups(after, &rest) orelse return false;
        // `::` stands for at least one zero group.
        if (head_len + rest_len + tail_len > 7) return false;
        fill = 8 - head_len - rest_len - tail_len;
    } else {
        head_len = groups(body, &head) orelse return false;
        if (head_len + tail_len != 8) return false;
    }
    var segments: [8]u16 = @splat(0);
    @memcpy(segments[0..head_len], head[0..head_len]);
    @memcpy(segments[head_len + fill ..][0..rest_len], rest[0..rest_len]);
    @memcpy(segments[8 - tail_len ..][0..tail_len], tail[0..tail_len]);
    for (segments, 0..) |segment, index| std.mem.writeInt(u16, out[2 * index ..][0..2], segment, .big);
    return true;
}

/// IPv4 or IPv6 (no brackets, no port) into `out[0..4]` or `out[0..16]`; the family, or 0.
pub fn ip(text: []const u8, out: *[16]u8) u32 {
    if (std.mem.indexOfScalar(u8, text, ':') != null) return if (parseV6(text, out)) 6 else 0;
    return if (parseV4(text, out[0..4])) 4 else 0;
}

/// `a.b.c.d:port` or `[v6]:port` into `out`; the family, or 0. A port is decimal digits that fit a u16 (Rust
/// allows leading zeros); a bracketed address must be IPv6 and a bare one IPv4.
pub fn socket(text: []const u8, out: *[18]u8) u32 {
    const bracketed = text.len > 0 and text[0] == '[';
    const close = std.mem.indexOfScalar(u8, text, if (bracketed) ']' else ':') orelse return 0;
    const colon = if (bracketed) close + 1 else close;
    if (colon >= text.len or text[colon] != ':') return 0;
    const digits = text[colon + 1 ..];
    if (digits.len == 0) return 0;
    var port: u32 = 0;
    for (digits) |c| {
        if (!isDigit(c)) return 0;
        port = port * 10 + (c - '0');
        if (port > std.math.maxInt(u16)) return 0;
    }
    const family = ip(text[@intFromBool(bracketed)..close], out[0..16]);
    if (family != (if (bracketed) @as(u32, 6) else 4)) return 0;
    std.mem.writeInt(u16, out[16..18], @intCast(port), builtin.cpu.arch.endian());
    return family;
}

/// The UTF-8 of `value` in `buffer`, or null when it is not a string or too long to be an address.
fn textOf(value: v8.Value, buffer: *[max_text]u8) ?[]const u8 {
    if (!value.isString()) return null;
    const string = v8.String.from_opaque(value.data.handle) orelse return null;
    const isolate = v8.Isolate.getCurrent();
    if (string.lenUtf8(isolate) > buffer.len) return null;
    return buffer[0..string.writeUtf8(isolate, buffer)];
}

/// The `Uint8Array` `object` aliased, if it has at least `len` bytes.
fn outOf(object: v8.Object, comptime len: usize) ?*[len]u8 {
    const bytes = binding.viewBytes(object.value) orelse return null;
    if (bytes.len < len) return null;
    return bytes[0..len];
}

/// `native.addr.parseIp(text, out)`: `out` is a `Uint8Array` of at least 16 bytes.
pub fn parseIp(_: *ScopeCore, text: v8.Value, out: v8.Object) u32 {
    var buffer: [max_text]u8 = undefined;
    const bytes = textOf(text, &buffer) orelse return 0;
    return ip(bytes, outOf(out, ip_len) orelse return 0);
}

/// `native.addr.parseSocket(text, out)`: `out` is a `Uint8Array` of at least 18 bytes.
pub fn parseSocket(_: *ScopeCore, text: v8.Value, out: v8.Object) u32 {
    var buffer: [max_text]u8 = undefined;
    const bytes = textOf(text, &buffer) orelse return 0;
    return socket(bytes, outOf(out, socket_len) orelse return 0);
}

test "ip: Rust's rules" {
    var out: [16]u8 = @splat(0);
    try std.testing.expectEqual(@as(u32, 4), ip("1.2.3.4", &out));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, out[0..4]);
    try std.testing.expectEqual(@as(u32, 6), ip("::ffff:1.2.3.4", &out));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 1, 2, 3, 4 }, &out);
    try std.testing.expectEqual(@as(u32, 6), ip("ABCD::EF", &out));
    try std.testing.expectEqualSlices(u8, &.{ 0xab, 0xcd, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xef }, &out);
    for ([_][]const u8{ "", "1.2.3", "1.2.3.4.5", "256.1.1.1", "01.2.3.4", "1.2.3.-4", ":::", "1::2::3", "12345::", "g::1", "1:2:3:4:5:6:7", "1:2:3:4:5:6:7:8:9", "1:2:3:4:5:6:7:8::", "::1%en0", "[::1]", "1.2.3.4:5", " 1.2.3.4", "1:2:3:4:5:6:7:1.2.3.4" }) |bad|
        try std.testing.expectEqual(@as(u32, 0), ip(bad, &out));
}

test "socket: Rust's rules" {
    var out: [18]u8 = @splat(0);
    try std.testing.expectEqual(@as(u32, 4), socket("1.2.3.4:00053", &out));
    try std.testing.expectEqual(@as(u16, 53), std.mem.readInt(u16, out[16..18], builtin.cpu.arch.endian()));
    try std.testing.expectEqual(@as(u32, 6), socket("[::1]:65535", &out));
    try std.testing.expectEqual(@as(u16, 65535), std.mem.readInt(u16, out[16..18], builtin.cpu.arch.endian()));
    for ([_][]const u8{ "1.2.3.4", "1.2.3.4:", "1.2.3.4:65536", "1.2.3.4:5a", "[1.2.3.4]:53", "::1:53", "[::1]", "[::1]53", "[::1:53", "[::1]]:53", ":53", "1.2.3.4:5:3", " 1.2.3.4:53", "1.2.3.4:99999999999999999999" }) |bad|
        try std.testing.expectEqual(@as(u32, 0), socket(bad, &out));
}
