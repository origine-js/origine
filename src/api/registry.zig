//! Records the host hands out by number: contexts, import handlers and graphs. Ids start at 1 and are
//! never reused, so a handle to a freed record is `StaleHandle` (it was issued) and not another
//! record's; a number never issued is `BadHandle`. Memory is proportional to the live records.

const std = @import("std");

pub fn Registry(comptime T: type) type {
    return struct {
        const Self = @This();

        map: std.AutoArrayHashMapUnmanaged(u32, *T) = .empty,
        next: u32 = 1,

        /// The id the next `put` must use. Fails once every id was handed out.
        pub fn issue(self: *Self) !u32 {
            if (self.next == 0) return error.OutOfMemory;
            return self.next;
        }

        /// Adds `item` under `id`, which must come from `issue` with no `put` in between.
        pub fn put(self: *Self, alloc: std.mem.Allocator, id: u32, item: *T) !void {
            std.debug.assert(id == self.next);
            try self.map.put(alloc, id, item);
            self.next +%= 1;
        }

        pub fn get(self: *const Self, id: u32) ?*T {
            return self.map.get(id);
        }

        /// Whether `id` was handed out once (it may be freed since).
        pub fn issued(self: *const Self, id: u32) bool {
            return id != 0 and (self.next == 0 or id < self.next);
        }

        /// Forgets `id`; the record is the caller's to free. Invalidates `values()`.
        pub fn remove(self: *Self, id: u32) void {
            _ = self.map.swapRemove(id);
        }

        /// The live records, in no particular order. Invalidated by `put` and `remove`.
        pub fn values(self: *const Self) []const *T {
            return self.map.values();
        }

        pub fn count(self: *const Self) usize {
            return self.map.count();
        }

        pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
            self.map.deinit(alloc);
        }
    };
}
