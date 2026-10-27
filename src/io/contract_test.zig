//! CONTRACT (docs/contracts.md, surface A): checks `c_api.zig` and the op/backend types against
//! the header `include/origine_io.h`, which is the source of truth. It parses the header text
//! (translate-c is not used: it does not terminate on the macOS SDK headers) and compares, for
//! the native target:
//!   * every `oio_*` function: same name set both ways, C calling convention, parameter and
//!     return ABI classes (integer width/signedness, pointer, const-ness of data pointers);
//!   * every struct (`oio_op`, `oio_stat`, `oio_options`, `oio_iovec`): field names, order,
//!     offsets, sizes and total size, against the Zig `extern struct`;
//!   * every `#define` and enum constant: same names and values as the Zig enums/decls
//!     (`op.Kind`, `op.O`, `backend.Caps`, `backend.Kind`, `backend.Mode`, `op.FallocFlags`,
//!     `op.fd_cwd`), both ways.
//! Run by `zig build test-io`. When it fails, change the header and the Zig side together, then
//! run `just gen-contracts` for the Rust bindings.
const std = @import("std");
const c_api = @import("c_api.zig");
const op_mod = @import("op.zig");
const backend = @import("backend.zig");

const header_text = @embedFile("include/origine_io.h");
const alloc = std.testing.allocator;

const ContractViolation = error{ContractViolation};

fn fail(comptime fmt: []const u8, args: anytype) ContractViolation {
    std.debug.print("origine_io.h contract: " ++ fmt ++ "\n", args);
    return error.ContractViolation;
}

// ---- C text helpers ----

/// The header without `/* */` and `//` comments (newlines kept).
fn stripComments(text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < text.len) {
        if (std.mem.startsWith(u8, text[i..], "/*")) {
            const end = std.mem.indexOfPos(u8, text, i + 2, "*/") orelse return error.UnterminatedComment;
            for (text[i .. end + 2]) |c| if (c == '\n') try out.append(alloc, '\n');
            try out.append(alloc, ' ');
            i = end + 2;
        } else if (std.mem.startsWith(u8, text[i..], "//")) {
            while (i < text.len and text[i] != '\n') i += 1;
        } else {
            try out.append(alloc, text[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

const Kind = enum { int, ptr, void };

/// How a C or Zig type travels over the ABI.
const Class = struct {
    kind: Kind,
    signed: bool = false,
    bits: u16 = 0,
    /// Pointer to data (not a function pointer) that is const-qualified.
    data_const: bool = false,
    /// Function pointers are compared by kind only.
    func: bool = false,

    fn size(c: Class) usize {
        return switch (c.kind) {
            .ptr => 8,
            .int => c.bits / 8,
            .void => 0,
        };
    }

    fn eql(a: Class, b: Class) bool {
        if (a.kind != b.kind) return false;
        return switch (a.kind) {
            .void => true,
            .int => a.signed == b.signed and a.bits == b.bits,
            .ptr => a.func == b.func and (a.func or a.data_const == b.data_const),
        };
    }
};

fn classifyC(raw: []const u8) !Class {
    const text = std.mem.trim(u8, raw, " \t\n");
    if (std.mem.indexOfScalar(u8, text, '(') != null) return .{ .kind = .ptr, .func = true };
    if (std.mem.indexOfScalar(u8, text, '*')) |star| {
        const stars = std.mem.count(u8, text, "*");
        const before = text[0..star];
        // `const T *` is const data; `T **` and `T *const *` are not compared.
        return .{ .kind = .ptr, .data_const = stars == 1 and std.mem.indexOf(u8, before, "const") != null };
    }
    const table = [_]struct { []const u8, Class }{
        .{ "void", .{ .kind = .void } },
        .{ "int", .{ .kind = .int, .signed = true, .bits = 32 } },
        .{ "int32_t", .{ .kind = .int, .signed = true, .bits = 32 } },
        .{ "uint32_t", .{ .kind = .int, .signed = false, .bits = 32 } },
        .{ "int64_t", .{ .kind = .int, .signed = true, .bits = 64 } },
        .{ "uint64_t", .{ .kind = .int, .signed = false, .bits = 64 } },
        .{ "size_t", .{ .kind = .int, .signed = false, .bits = 64 } },
        .{ "intptr_t", .{ .kind = .int, .signed = true, .bits = 64 } },
        .{ "oio_fd", .{ .kind = .int, .signed = true, .bits = 64 } },
        .{ "oio_cb", .{ .kind = .ptr, .func = true } },
    };
    for (table) |entry| if (std.mem.eql(u8, entry[0], text)) return entry[1];
    return fail("header type `{s}` is not known to contract_test.zig; add it to classifyC", .{text});
}

fn classifyZig(comptime T: type) Class {
    return switch (@typeInfo(T)) {
        .int => |i| .{ .kind = .int, .signed = i.signedness == .signed, .bits = i.bits },
        .void => .{ .kind = .void },
        .optional => |o| classifyZig(o.child),
        .pointer => |p| .{
            .kind = .ptr,
            .func = @typeInfo(p.child) == .@"fn",
            .data_const = p.attrs.@"const",
        },
        else => @compileError("contract_test: unsupported ABI type " ++ @typeName(T)),
    };
}

// ---- header model ----

const Param = struct { class: Class, text: []const u8 };
const Func = struct { name: []const u8, ret: Class, params: []Param };
const Field = struct { name: []const u8, class: Class, count: usize };
const Struct = struct { name: []const u8, fields: []Field };
const Const = struct { name: []const u8, value: i128 };

const Header = struct {
    funcs: std.ArrayList(Func) = .empty,
    structs: std.ArrayList(Struct) = .empty,
    consts: std.ArrayList(Const) = .empty,
    /// Owns the names copied out of temporary buffers.
    strings: std.heap.ArenaAllocator = .init(alloc),

    fn deinit(h: *Header) void {
        h.strings.deinit();
        for (h.funcs.items) |f| alloc.free(f.params);
        for (h.structs.items) |s| alloc.free(s.fields);
        h.funcs.deinit(alloc);
        h.structs.deinit(alloc);
        h.consts.deinit(alloc);
    }
};

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn evalInt(raw: []const u8) !i128 {
    var text = std.mem.trim(u8, raw, " \t");
    while (text.len > 1 and text[0] == '(' and text[text.len - 1] == ')') text = std.mem.trim(u8, text[1 .. text.len - 1], " \t");
    if (std.mem.indexOf(u8, text, "<<")) |at| return (try evalInt(text[0..at])) << @intCast(try evalInt(text[at + 2 ..]));
    var neg = false;
    if (text.len > 0 and text[0] == '-') {
        neg = true;
        text = std.mem.trim(u8, text[1..], " ");
    }
    while (text.len > 0 and (text[text.len - 1] == 'u' or text[text.len - 1] == 'l' or text[text.len - 1] == 'U' or text[text.len - 1] == 'L')) text = text[0 .. text.len - 1];
    const v = std.fmt.parseInt(i128, text, 0) catch return fail("cannot evaluate header constant `{s}`", .{raw});
    return if (neg) -v else v;
}

fn parseHeader(h: *Header, text: []const u8) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (std.mem.startsWith(u8, line, "#define ")) {
            var it = std.mem.tokenizeAny(u8, line["#define ".len..], " \t");
            const name = it.next().?;
            const value = std.mem.trim(u8, it.rest(), " \t");
            if (value.len == 0 or !std.mem.startsWith(u8, name, "OIO_") or std.mem.indexOfScalar(u8, name, '(') != null) continue;
            try h.consts.append(alloc, .{ .name = name, .value = try evalInt(value) });
        } else if (std.mem.startsWith(u8, line, "enum ") and std.mem.indexOfScalar(u8, line, '{') != null) {
            // Members up to the closing brace (possibly over several lines).
            var body: std.ArrayList(u8) = .empty;
            defer body.deinit(alloc);
            var cur = line[std.mem.indexOfScalar(u8, line, '{').? + 1 ..];
            while (true) {
                if (std.mem.indexOfScalar(u8, cur, '}')) |end| {
                    try body.appendSlice(alloc, cur[0..end]);
                    break;
                }
                try body.appendSlice(alloc, cur);
                try body.append(alloc, ' ');
                cur = std.mem.trim(u8, lines.next() orelse return fail("unterminated enum", .{}), " \t\r");
            }
            var members = std.mem.splitScalar(u8, body.items, ',');
            var next: i128 = 0;
            while (members.next()) |m_raw| {
                const m = std.mem.trim(u8, m_raw, " \t\r\n");
                if (m.len == 0) continue;
                if (std.mem.indexOfScalar(u8, m, '=')) |eq| {
                    next = try evalInt(m[eq + 1 ..]);
                    try h.consts.append(alloc, .{ .name = try h.strings.allocator().dupe(u8, std.mem.trim(u8, m[0..eq], " ")), .value = next });
                } else try h.consts.append(alloc, .{ .name = try h.strings.allocator().dupe(u8, m), .value = next });
                next += 1;
            }
        } else if (std.mem.startsWith(u8, line, "struct oio_") or (std.mem.startsWith(u8, line, "typedef struct oio_") and std.mem.endsWith(u8, line, "{")) or std.mem.startsWith(u8, line, "typedef struct oio_")) {
            const open = std.mem.indexOfScalar(u8, line, '{') orelse continue; // forward declaration
            const head = std.mem.trim(u8, line[0..open], " ");
            const name = head[std.mem.lastIndexOfScalar(u8, head, ' ').? + 1 ..];
            var body: std.ArrayList(u8) = .empty;
            defer body.deinit(alloc);
            var cur = line[open + 1 ..];
            while (true) {
                if (std.mem.indexOfScalar(u8, cur, '}')) |end| {
                    try body.appendSlice(alloc, cur[0..end]);
                    break;
                }
                try body.appendSlice(alloc, cur);
                try body.append(alloc, ' ');
                cur = std.mem.trim(u8, lines.next() orelse return fail("unterminated struct", .{}), " \t\r");
            }
            var fields: std.ArrayList(Field) = .empty;
            errdefer fields.deinit(alloc);
            var decls = std.mem.splitScalar(u8, body.items, ';');
            while (decls.next()) |d_raw| {
                const d = std.mem.trim(u8, d_raw, " \t\r\n");
                if (d.len == 0) continue;
                var count: usize = 1;
                var decl = d;
                if (std.mem.indexOfScalar(u8, d, '[')) |lb| {
                    count = try std.fmt.parseInt(usize, d[lb + 1 .. std.mem.indexOfScalar(u8, d, ']').?], 10);
                    decl = d[0..lb];
                }
                var end = decl.len;
                while (end > 0 and isIdent(decl[end - 1])) end -= 1;
                const type_text = std.mem.trim(u8, decl[0..end], " ");
                // `uint32_t a, b;` is not used; one field per declaration keeps offsets obvious.
                try fields.append(alloc, .{ .name = try h.strings.allocator().dupe(u8, decl[end..]), .class = try classifyC(type_text), .count = count });
            }
            try h.structs.append(alloc, .{ .name = try h.strings.allocator().dupe(u8, name), .fields = try fields.toOwnedSlice(alloc) });
        } else if (functionLine(line)) |paren| {
            var end = paren;
            while (end > 0 and isIdent(line[end - 1])) end -= 1;
            const name = line[end..paren];
            if (!std.mem.startsWith(u8, name, "oio_")) continue;
            const close = std.mem.lastIndexOfScalar(u8, line, ')').?;
            var params: std.ArrayList(Param) = .empty;
            errdefer params.deinit(alloc);
            var depth: usize = 0;
            var start = paren + 1;
            for (line[paren + 1 .. close + 1], paren + 1..) |c, i| {
                if (c == '(') depth += 1;
                if (depth == 0 and (c == ',' or i == close)) {
                    const p = std.mem.trim(u8, line[start..i], " ");
                    start = i + 1;
                    if (std.mem.eql(u8, p, "void") or p.len == 0) continue;
                    var tend = p.len;
                    if (std.mem.indexOf(u8, p, "(*") == null) {
                        while (tend > 0 and isIdent(p[tend - 1])) tend -= 1;
                    }
                    try params.append(alloc, .{ .class = try classifyC(if (tend == p.len) p else p[0..tend]), .text = p });
                }
                if (c == ')' and depth > 0) depth -= 1;
            }
            try h.funcs.append(alloc, .{ .name = name, .ret = try classifyC(line[0..end]), .params = try params.toOwnedSlice(alloc) });
        }
    }
}

/// Index of the `(` of a function declaration line (`ret oio_name(...);`), else null.
fn functionLine(line: []const u8) ?usize {
    if (!std.mem.endsWith(u8, line, ");")) return null;
    if (std.mem.startsWith(u8, line, "typedef") or std.mem.startsWith(u8, line, "#")) return null;
    return std.mem.indexOfScalar(u8, line, '(');
}

// ---- Zig side ----

fn checkFunctions(h: *const Header) !void {
    inline for (@typeInfo(c_api).@"struct".decl_names) |name| {
        if (comptime std.mem.startsWith(u8, name, "oio_")) {
            var found = false;
            for (h.funcs.items) |f| found = found or std.mem.eql(u8, f.name, name);
            if (!found) return fail("c_api.{s} is exported but not declared in origine_io.h", .{name});
        }
    }
    for (h.funcs.items) |f| {
        inline for (@typeInfo(c_api).@"struct".decl_names) |name| {
            if (comptime std.mem.startsWith(u8, name, "oio_")) {
                if (std.mem.eql(u8, name, f.name)) {
                    const info = @typeInfo(@TypeOf(@field(c_api, name))).@"fn";
                    if (!info.attrs.@"callconv".eql(.c)) return fail("{s}: not callconv(.c)", .{name});
                    if (info.param_types.len != f.params.len) return fail("{s}: header has {d} parameters, c_api.zig {d}", .{ name, f.params.len, info.param_types.len });
                    if (!f.ret.eql(classifyZig(info.return_type.?))) return fail("{s}: return type differs from the header", .{name});
                    inline for (info.param_types, 0..) |P, i| {
                        if (!f.params[i].class.eql(classifyZig(P.?))) return fail("{s}: parameter {d} (`{s}`) differs from the header", .{ name, i, f.params[i].text });
                    }
                    break;
                }
            }
        } else return fail("{s} is declared in origine_io.h but not exported by c_api.zig (`pub export fn`)", .{f.name});
    }
}

fn checkStruct(h: *const Header, comptime c_name: []const u8, comptime T: type) !void {
    for (h.structs.items) |s| {
        if (!std.mem.eql(u8, s.name, c_name)) continue;
        const names = @typeInfo(T).@"struct".field_names;
        if (s.fields.len != names.len) return fail("struct {s}: header has {d} fields, {s} has {d}", .{ c_name, s.fields.len, @typeName(T), names.len });
        var offset: usize = 0;
        var max_align: usize = 1;
        inline for (names, 0..) |n, i| {
            const hf = s.fields[i];
            if (!std.mem.eql(u8, hf.name, n)) return fail("struct {s}: field {d} is `{s}` in the header, `{s}` in Zig", .{ c_name, i, hf.name, n });
            const field_size = hf.class.size() * hf.count;
            const field_align = hf.class.size();
            max_align = @max(max_align, field_align);
            offset = std.mem.alignForward(usize, offset, field_align);
            if (@offsetOf(T, n) != offset) return fail("struct {s}.{s}: offset {d} in the header, {d} in Zig", .{ c_name, n, offset, @offsetOf(T, n) });
            if (@sizeOf(@FieldType(T, n)) != field_size) return fail("struct {s}.{s}: size {d} in the header, {d} in Zig", .{ c_name, n, field_size, @sizeOf(@FieldType(T, n)) });
            offset += field_size;
        }
        offset = std.mem.alignForward(usize, offset, max_align);
        if (@sizeOf(T) != offset) return fail("struct {s}: size {d} in the header, {d} in Zig", .{ c_name, offset, @sizeOf(T) });
        return;
    }
    return fail("struct {s} is not defined in origine_io.h", .{c_name});
}

/// Constants of a Zig enum (`field_names`/`field_values`), a packed struct of flags (one bit per
/// non-padding field) or a struct of `u64` decls, with their names upper-cased.
fn zigConsts(comptime T: type) []const Const {
    comptime {
        var out: []const Const = &.{};
        switch (@typeInfo(T)) {
            .@"enum" => |e| for (e.field_names, e.field_values) |n, v| {
                out = out ++ [_]Const{.{ .name = upper(n), .value = v }};
            },
            .@"struct" => |s| if (s.layout == .@"packed") {
                for (s.field_names) |n| {
                    if (n[0] != '_') out = out ++ [_]Const{.{ .name = upper(n), .value = 1 << @bitOffsetOf(T, n) }};
                }
            } else for (s.decl_names) |n| {
                const v = @field(T, n);
                if (@TypeOf(v) == u64) out = out ++ [_]Const{.{ .name = upper(n), .value = v }};
            },
            else => @compileError("zigConsts"),
        }
        return out;
    }
}

fn upper(comptime s: []const u8) []const u8 {
    comptime {
        var buf: [s.len]u8 = undefined;
        for (s, 0..) |c, i| buf[i] = std.ascii.toUpper(c);
        const final = buf;
        return &final;
    }
}

/// Header constants named `<prefix>NAME` (or, with an empty prefix, every one not claimed by
/// another group) must be exactly `zig`'s, with the same values.
fn checkGroup(h: *const Header, comptime prefix: []const u8, comptime exclude: []const []const u8, comptime T: type) !void {
    const zig = comptime zigConsts(T);
    var seen: usize = 0;
    for (h.consts.items) |c| {
        if (!inGroup(c.name, prefix, exclude)) continue;
        seen += 1;
        const short = c.name[(if (prefix.len == 0) "OIO_" else prefix).len..];
        var found = false;
        for (zig) |z| {
            if (!std.mem.eql(u8, z.name, short)) continue;
            found = true;
            if (z.value != c.value) return fail("{s}: {d} in the header, {d} in {s}", .{ c.name, c.value, z.value, @typeName(T) });
        }
        if (!found) return fail("{s} is in the header but {s} has no member `{s}`", .{ c.name, @typeName(T), short });
    }
    if (seen != zig.len) return fail("{s} has {d} members, the header {d} constants with prefix `{s}`", .{ @typeName(T), zig.len, seen, prefix });
}

fn inGroup(name: []const u8, prefix: []const u8, exclude: []const []const u8) bool {
    if (!std.mem.startsWith(u8, name, "OIO_")) return false;
    if (prefix.len == 0) {
        for (exclude) |e| if (std.mem.startsWith(u8, name, e)) return false;
        return true;
    }
    return std.mem.startsWith(u8, name, prefix);
}

test "c_api.zig, op.zig and backend.zig match include/origine_io.h" {
    const stripped = try stripComments(header_text);
    defer alloc.free(stripped);
    var h: Header = .{};
    defer h.deinit();
    try parseHeader(&h, stripped);
    try std.testing.expect(h.funcs.items.len > 30);

    try checkFunctions(&h);
    try checkStruct(&h, "oio_op", op_mod.Op);
    try checkStruct(&h, "oio_stat", op_mod.Stat);
    try checkStruct(&h, "oio_iovec", op_mod.Iovec);
    try checkStruct(&h, "oio_options", backend.Options);
    try std.testing.expectEqual(@as(usize, 4), h.structs.items.len);

    const others = [_][]const u8{ "OIO_O_", "OIO_CAP_", "OIO_FALLOC_", "OIO_BACKEND_", "OIO_RUN_", "OIO_FDCWD" };
    try checkGroup(&h, "OIO_O_", &.{}, op_mod.O);
    try checkGroup(&h, "OIO_CAP_", &.{}, backend.Caps);
    try checkGroup(&h, "OIO_FALLOC_", &.{}, op_mod.FallocFlags);
    try checkGroup(&h, "OIO_BACKEND_", &.{}, backend.Kind);
    try checkGroup(&h, "OIO_RUN_", &.{}, backend.Mode);
    try checkGroup(&h, "", &others, op_mod.Kind);
    for (h.consts.items) |c| {
        if (std.mem.eql(u8, c.name, "OIO_FDCWD") and c.value != op_mod.fd_cwd) return fail("OIO_FDCWD is {d}, op.fd_cwd {d}", .{ c.value, op_mod.fd_cwd });
    }
}
