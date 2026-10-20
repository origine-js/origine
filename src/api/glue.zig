//! The guest-side glue that builds the `api` object, assembled from `src/js/glue/`.
//!
//! Each part is a JS expression. `source` splices them into one strict-mode function
//! expression `(native) => api`, so the parts share a realm and nothing else. `index.js`
//! composes the capability factories; `host.zig` evaluates the result once per scope.
const std = @import("std");

/// Script origin reported in stack traces.
pub const origin = "engine:api.js";

pub const source = std.fmt.comptimePrint(
    \\(native) => {{
    \\  'use strict';
    \\  const util = ({[util]s})(native);
    \\  return ({[index]s})(native, util, ({[fs]s}), ({[env]s}), ({[scope]s}));
    \\}}
, .{
    .util = @embedFile("../js/glue/util.js"),
    .index = @embedFile("../js/glue/index.js"),
    .fs = @embedFile("../js/glue/fs.js"),
    .env = @embedFile("../js/glue/env.js"),
    .scope = @embedFile("../js/glue/scope.js"),
});
