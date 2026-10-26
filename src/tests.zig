//! Behavioral tests use the same exported modules as embedders.

test {
    _ = @import("tests/managed/repl.zig");
    _ = @import("tests/managed/ownership.zig");
    _ = @import("tests/managed/runtime.zig");
    _ = @import("tests/managed/disposal.zig");
    _ = @import("tests/managed/errors.zig");
    _ = @import("tests/managed/capabilities.zig");
    _ = @import("tests/managed/modules.zig");
    _ = @import("tests/managed/import_maps.zig");
    _ = @import("tests/managed/module_map.zig");
    _ = @import("tests/managed/loading.zig");
    _ = @import("tests/managed/cache.zig");
    _ = @import("tests/managed/api.zig");
    _ = @import("tests/managed/snapshot.zig");
    _ = @import("tests/managed/init_snapshot.zig");
    _ = @import("tests/managed/init_cache.zig");
    _ = @import("tests/managed/code_cache.zig");
    _ = @import("tests/managed/native_snapshot.zig");
}
