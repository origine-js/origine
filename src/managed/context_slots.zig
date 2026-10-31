//! The embedder-data slots of a scope's context. Every writer takes its slot from here: the enum
//! makes two names for one slot a compile error (a shared slot silently loses one value, and which
//! one is decided by the order of unrelated initializers).
const Slot = enum(u32) {
    /// The managed `Scope` (process memory, null in a snapshot).
    scope = 1,
    /// The api host's `Rebinder` (process memory, null in a snapshot).
    rebinder = 2,
    /// The glue bundle array.
    glue = 3,
    /// The bootstrap helpers array.
    bootstrap = 4,
    /// The snapshot data index of the glue's handles module, in a context made for a snapshot.
    glue_handles = 5,
};

pub const scope: comptime_int = @backingInt(Slot.scope);
pub const rebinder: comptime_int = @backingInt(Slot.rebinder);
pub const glue: comptime_int = @backingInt(Slot.glue);
pub const bootstrap: comptime_int = @backingInt(Slot.bootstrap);
pub const glue_handles: comptime_int = @backingInt(Slot.glue_handles);
