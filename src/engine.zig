//! Process-wide V8 initialization and teardown, independent of managed runtimes.
const v8 = @import("@v8");
const StartupTrace = @import("@diagnostics").StartupTrace;

/// Owns the process V8 platform and initialized engine. Do not copy an owner.
/// Create once per process on the coordinating thread; V8 cannot be reinitialized
/// after deinit. All isolates, runtimes, handles and worker users must finish first.
pub const Engine = struct {
    /// Borrowed by callers for foreground job pumping until deinit begins.
    platform: v8.Platform,

    pub const Options = struct {
        thread_pool_size: u32 = 1,
        idle_task_support: bool = true,
        /// Optional trace borrowed only until init returns; never retained.
        trace: ?*StartupTrace = null,
    };

    /// Copies options and borrows trace through return. Returns the sole owner of
    /// the platform and initialized V8; release with deinit after all isolates die.
    /// Platform/V8 initialization failures are fatal in the underlying raw interface;
    /// there is no recoverable error or partially initialized owner returned.
    pub fn init(options: Options) Engine {
        const platform = v8.Platform.initDefault(options.thread_pool_size, options.idle_task_support);
        if (options.trace) |trace| trace.mark("platform_create");
        v8.V8.initializePlatform(platform);
        v8.V8.initialize();
        if (options.trace) |trace| trace.mark("v8_initialize");
        return .{ .platform = platform };
    }

    /// Consumes this owner on the coordinating thread; all isolates/runtimes and
    /// caller-owned handles must already be released and worker users joined.
    /// Disposes V8, unregisters the platform, then frees it. Do not reuse self or
    /// initialize another engine afterward. Process-owned ICU storage remains live.
    pub fn deinit(self: *Engine) void {
        v8.V8.dispose();
        v8.V8.disposePlatform();
        self.platform.deinit();
        self.* = undefined;
    }
};
