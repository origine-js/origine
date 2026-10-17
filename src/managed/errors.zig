const v8 = @import("@v8");

/// Caller-owned error details. Initialize with .{}; do not copy populated instances.
/// Passing &info borrows it through the call and releases any previous details first.
/// Call deinit before Runtime.destroy; passing null discards error details.
pub const ErrorInfo = struct {
    /// Retained original thrown/cached JS value, owned by this ErrorInfo. Null on
    /// success or when no JS value was caught (including engine termination).
    /// Borrow it for inspection; do not independently deinit it or outlive ErrorInfo.
    exception: ?v8.Global.Of(v8.Value) = null,

    /// Releases retained error details and resets this value; safe to call repeatedly.
    /// The originating Runtime must still be alive.
    pub fn deinit(self: *ErrorInfo) void {
        if (self.exception) |exception| exception.deinit();
        self.* = .{};
    }
};

/// Borrows the live TryCatch through the call; copies a caught exception into
/// error_info only when its slot is empty. The caller owns the copy and must
/// deinit the ErrorInfo before Runtime.destroy. Retains nothing else.
pub fn captureException(isolate: v8.Isolate, tc_scope: *const v8.TryCatch, error_info: ?*ErrorInfo) void {
    if (error_info) |out| if (out.exception == null) {
        if (tc_scope.getException()) |exception| out.exception = .new(isolate, exception);
    };
}
