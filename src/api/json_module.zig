//! JSON modules: an import carrying the attribute `type: "json"` is served as a module whose
//! default export is the parsed file, whatever the loader read it from.
const std = @import("std");
const module_types = @import("../managed/module_types.zig");

/// Whether `attributes` ask for a JSON module.
pub fn requested(attributes: []const module_types.ImportAttribute) bool {
    for (attributes) |attribute| {
        if (std.mem.eql(u8, attribute.key, "type") and std.mem.eql(u8, attribute.value, "json")) return true;
    }
    return false;
}

/// Module source exporting `JSON.parse(text)` as default. `text` is embedded as a string literal,
/// so V8 does the parsing: malformed JSON throws a SyntaxError when the module evaluates, and
/// keys like `__proto__` stay plain data. Allocated from `allocator`; borrows `text` for the call.
pub fn wrap(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("export default JSON.parse(");
    try std.json.Stringify.value(text, .{}, &out.writer);
    try out.writer.writeAll(");");
    return out.toOwnedSlice();
}

test "wrap embeds the text as an escaped string literal" {
    const source = try wrap(std.testing.allocator, "{\"k\": \"a\\nb\"}");
    defer std.testing.allocator.free(source);
    try std.testing.expectEqualStrings("export default JSON.parse(\"{\\\"k\\\": \\\"a\\\\nb\\\"}\");", source);
    try std.testing.expect(requested(&.{.{ .key = "type", .value = "json" }}));
    try std.testing.expect(!requested(&.{.{ .key = "type", .value = "css" }}));
}
