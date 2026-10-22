//! The guest-side glue that builds the `api` object, assembled from `src/js/glue/`.
//!
//! Each part is a JS expression. `source` splices them into one strict-mode function
//! expression `(native) => api`, so the parts share a realm and nothing else. `index.js`
//! composes the capability factories; `host.zig` evaluates the result once per scope.
const std = @import("std");

/// Script origin reported in stack traces.
pub const origin = "engine:api.js";

/// A glue part as a bare expression: the formatter ends each file with `;`, which would not
/// parse inside the parentheses `source` puts around it.
fn part(comptime text: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, text, " \t\r\n");
    return if (trimmed.len != 0 and trimmed[trimmed.len - 1] == ';') trimmed[0 .. trimmed.len - 1] else trimmed;
}

pub const source = std.fmt.comptimePrint(
    \\(native) => {{
    \\  'use strict';
    \\  const util = ({[util]s})(native);
    \\  return ({[index]s})(native, util, ({[fs]s}), ({[env]s}), ({[scope]s}), ({[io]s}), ({[net]s}));
    \\}}
, .{
    .util = part(@embedFile("../js/glue/util.js")),
    .index = part(@embedFile("../js/glue/index.js")),
    .fs = part(@embedFile("../js/glue/fs.js")),
    .env = part(@embedFile("../js/glue/env.js")),
    .scope = part(@embedFile("../js/glue/scope.js")),
    .io = part(@embedFile("../js/glue/io.js")),
    .net = part(@embedFile("../js/glue/net.js")),
});
