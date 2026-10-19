//! Every embedded `origine:` module, in one table. Add a module by writing a
//! `std_*.zig` with a `modules(State)` function and concatenating it here.
const Module = @import("module.zig").Module;

pub const all: [modules.len]Module = modules;

const modules = std_io.modules() ++
    std_errno.modules() ++
    std_quansync.modules() ++
    std_fs.modules() ++
    std_text.modules();

const std_io = @import("std_io.zig");
const std_errno = @import("std_errno.zig");
const std_quansync = @import("std_quansync.zig");
const std_fs = @import("std_fs.zig");
const std_text = @import("std_text.zig");
