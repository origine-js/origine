//! Every embedded `origine:` module, in one table. Add a module by writing a
//! `std_*.zig` with a `modules()` function and concatenating it here.
const Module = @import("../module.zig").Module;

pub const all: [modules.len]Module = modules;

const modules = std_io.modules() ++
    std_errno.modules() ++
    std_quansync.modules() ++
    std_fs.modules() ++
    std_text.modules() ++
    std_transformer_oxc.modules();

const std_io = @import("io.zig");
const std_errno = @import("errno.zig");
const std_quansync = @import("quansync.zig");
const std_fs = @import("fs.zig");
const std_text = @import("text.zig");
const std_transformer_oxc = @import("transformer/oxc.zig");
