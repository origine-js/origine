//! Every embedded `origine:` module, in one table. Add a module by writing a
//! `std_*.zig` with a `modules()` function and concatenating it here.
const Module = @import("../module.zig").Module;

pub const all: [modules.len]Module = modules;

const modules = @import("errors.zig").modules() ++ std_io.modules() ++
    std_errno.modules() ++
    std_quansync.modules() ++
    std_fs.modules() ++
    std_text.modules() ++
    std_debug.modules() ++
    std_data.modules() ++
    std_dns.modules() ++
    std_net.modules() ++
    std_graph.modules() ++
    std_transformer_oxc.modules();

const std_io = @import("io.zig");
const std_errno = @import("errno.zig");
const std_quansync = @import("quansync.zig");
const std_fs = @import("fs.zig");
const std_text = @import("text.zig");
const std_debug = @import("debug.zig");
const std_data = @import("data.zig");
const std_dns = @import("dns.zig");
const std_net = @import("net.zig");
const std_graph = @import("graph.zig");
const std_transformer_oxc = @import("transformer/oxc.zig");
