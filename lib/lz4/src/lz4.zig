//! Zig wrapper for LZ4 1.10.0 (lz4.c, lz4hc.c): the raw block format, plus `pack`/`unpack`, a block
//! behind a little-endian u32 holding the decompressed length. The C ABI is private to this file.
//!
//! The compressor (`compressHc`, `pack`) is for build-time tools; a final link that only calls
//! `decompress`/`unpack` drops it.
const std = @import("std");

/// The C library's ABI; nothing outside this file calls it.
const c = struct {
    extern fn LZ4_compressBound(input_size: c_int) c_int;
    extern fn LZ4_compress_HC(src: [*]const u8, dst: [*]u8, src_size: c_int, dst_capacity: c_int, level: c_int) c_int;
    extern fn LZ4_decompress_safe(src: [*]const u8, dst: [*]u8, compressed_size: c_int, dst_capacity: c_int) c_int;
};

/// Largest input or output the C API addresses (its sizes are `int`s).
pub const max_len: usize = std.math.maxInt(c_int);
/// LZ4HC_CLEVEL_MAX: the smallest output the format allows, at the slowest compression.
pub const hc_max_level = 12;
/// LZ4's own bound for inputs up to `max_len / 2`; `compressBound` returns it.
pub const max_input_len: usize = max_len / 2;

pub const Error = error{
    /// The input is longer than the C API addresses.
    InputTooLarge,
    /// The compressor produced nothing (the destination was too small).
    CompressFailed,
    /// The compressed data is truncated, inconsistent, or does not fill the output exactly.
    Corrupt,
};

/// Bytes `compressHc` may write for `input_len` input bytes.
pub fn compressBound(input_len: usize) Error!usize {
    if (input_len > max_input_len) return error.InputTooLarge;
    return @intCast(c.LZ4_compressBound(@intCast(input_len)));
}

/// Compresses `src` into `dst` as one LZ4 block with the HC compressor at `level` (clamped by LZ4
/// to its range). `dst` must hold at least `compressBound(src.len)` bytes to be sure of success.
/// Returns the block's length.
pub fn compressHc(dst: []u8, src: []const u8, level: u8) Error!usize {
    if (src.len > max_input_len or dst.len > max_len) return error.InputTooLarge;
    const n = c.LZ4_compress_HC(src.ptr, dst.ptr, @intCast(src.len), @intCast(dst.len), level);
    if (n <= 0) return error.CompressFailed;
    return @intCast(n);
}

/// Expands one LZ4 block that must decompress to exactly `dst.len` bytes. Never writes outside
/// `dst` or reads outside `src`, whatever `src` holds.
pub fn decompress(dst: []u8, src: []const u8) Error!void {
    if (dst.len > max_len or src.len > max_len) return error.Corrupt;
    const n = c.LZ4_decompress_safe(src.ptr, dst.ptr, @intCast(src.len), @intCast(dst.len));
    if (n < 0 or @as(usize, @intCast(n)) != dst.len) return error.Corrupt;
}

const header_len = @sizeOf(u32);

/// Compresses `data` with `compressHc` at `hc_max_level` into the `unpack` format. Borrows `data`;
/// the caller frees the result with `alloc`.
pub fn pack(alloc: std.mem.Allocator, data: []const u8) (Error || std.mem.Allocator.Error)![]u8 {
    const bound = try compressBound(data.len);
    const buf = try alloc.alloc(u8, header_len + bound);
    errdefer alloc.free(buf);
    std.mem.writeInt(u32, buf[0..header_len], @intCast(data.len), .little);
    const n = try compressHc(buf[header_len..], data, hc_max_level);
    return alloc.realloc(buf, header_len + n);
}

/// Expands `pack`'s output into a 16-byte aligned buffer (the alignment V8 requires of a
/// snapshot). Borrows `packed_data`; the caller frees the result with `alloc`. Truncated or
/// inconsistent input is `error.Corrupt`.
pub fn unpack(alloc: std.mem.Allocator, packed_data: []const u8) (Error || std.mem.Allocator.Error)![]align(16) u8 {
    if (packed_data.len < header_len) return error.Corrupt;
    const len: usize = std.mem.readInt(u32, packed_data[0..header_len], .little);
    if (len > max_len) return error.Corrupt;
    const out = try alloc.alignedAlloc(u8, .@"16", len);
    errdefer alloc.free(out);
    try decompress(out, packed_data[header_len..]);
    return out;
}

test "pack and unpack round-trip" {
    const alloc = std.testing.allocator;
    var data: [4096]u8 = undefined;
    for (&data, 0..) |*byte, i| byte.* = @truncate(i * i / 7);
    const packed_data = try pack(alloc, &data);
    defer alloc.free(packed_data);
    try std.testing.expect(packed_data.len < data.len);
    const unpacked = try unpack(alloc, packed_data);
    defer alloc.free(unpacked);
    try std.testing.expectEqualSlices(u8, &data, unpacked);
}

test "empty input" {
    const alloc = std.testing.allocator;
    const packed_data = try pack(alloc, "");
    defer alloc.free(packed_data);
    const unpacked = try unpack(alloc, packed_data);
    defer alloc.free(unpacked);
    try std.testing.expectEqual(@as(usize, 0), unpacked.len);
}

test "unpack rejects truncated and inconsistent input" {
    const alloc = std.testing.allocator;
    var data: [480]u8 = undefined;
    for (&data, 0..) |*byte, i| byte.* = "abc"[i % 3];
    const packed_data = try pack(alloc, &data);
    defer alloc.free(packed_data);
    try std.testing.expectError(error.Corrupt, unpack(alloc, packed_data[0..2]));
    try std.testing.expectError(error.Corrupt, unpack(alloc, packed_data[0 .. packed_data.len - 3]));
    const wrong_len = try alloc.dupe(u8, packed_data);
    defer alloc.free(wrong_len);
    std.mem.writeInt(u32, wrong_len[0..4], @intCast(data.len + 1), .little);
    try std.testing.expectError(error.Corrupt, unpack(alloc, wrong_len));
}

test "decompress never writes outside the output on garbage" {
    var out: [64 + 8]u8 = @splat(0xaa);
    var prng = std.Random.DefaultPrng.init(1);
    var garbage: [128]u8 = undefined;
    for (0..2000) |_| {
        prng.random().bytes(&garbage);
        decompress(out[0..64], garbage[0 .. 1 + prng.random().uintLessThan(usize, garbage.len)]) catch {};
        try std.testing.expectEqualSlices(u8, &@as([8]u8, @splat(0xaa)), out[64..]);
    }
}
