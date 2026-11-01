//! Behavioral tests use the same exported modules as embedders.

test {
    _ = @import("tests/managed/sys.zig");
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
    _ = @import("tests/managed/shared_link.zig");
    _ = @import("tests/managed/async_resolve.zig");
    _ = @import("tests/managed/cache.zig");
    _ = @import("tests/managed/api.zig");
    _ = @import("tests/managed/fast_values.zig");
    _ = @import("tests/managed/js_handles.zig");
    _ = @import("tests/managed/thread_isolate.zig");
    _ = @import("tests/managed/channel.zig");
    _ = @import("tests/managed/isolate.zig");
    _ = @import("tests/managed/net_iter.zig");
    _ = @import("tests/managed/net_lifecycle.zig");
    _ = @import("tests/managed/snapshot_api.zig");
    _ = @import("tests/managed/snapshot.zig");
    _ = @import("tests/managed/init_snapshot.zig");
    _ = @import("tests/managed/init_cache.zig");
    _ = @import("tests/managed/cache_dir.zig");
    _ = @import("tests/managed/code_cache.zig");
    _ = @import("tests/managed/native_snapshot.zig");
}
