//! Zig bindings for mimalloc 3.6.0, the allocator Zig, V8 and Rust share in this process.
//!
//! Layers, from thin to convenient:
//!   * `c`          the raw C ABI (`c.zig`); only for what the wrappers do not cover.
//!   * functions    `free`, `collect`, `usableSize`, `processInfo`, ... on this namespace.
//!   * `Heap`       first-class heaps (any thread may allocate from or free into one), `Theap` the
//!                  thread-local variant, `Arena` memory the allocator is told to manage.
//!   * `allocator`  a process-lifetime `std.mem.Allocator`; `Heap.allocator` and `Theap.allocator`
//!                  give the same for one heap.
//!   * `Option`, `Tuning` runtime options; `stats` statistics.
//!
//! Does not replace libc malloc/free by itself; V8's `base::Malloc` family is routed here by
//! lib/v8_zig/build-tools/patches/v8/0004-mimalloc.patch whenever this archive is linked.
//!
//! Performance, following upstream's "getting the best performance":
//!   * build flags: this package compiles with `-Dopt_arch` (MI_OPT_ARCH) by default;
//!   * zero-initialize with `allocZeroed`/`Heap.allocZeroed`, never `alloc` plus `@memset`;
//!   * blocks up to `small_size_max` bytes take `allocSmall`'s shorter path, and `allocator`
//!     and the heap allocators pick it by themselves;
//!   * free with `freeSized` when the exact allocation size is at hand (see its contract);
//!   * a runtime that already keeps per-thread state fetches `Theap.default()` once per thread
//!     and allocates through it, skipping the thread-local lookup;
//!   * options (`Tuning`): large OS pages, huge pages, `purge_delay`, transparent huge pages.
const std = @import("std");
const Alignment = std.mem.Alignment;

pub const c = @import("c.zig");
pub const Option = @import("options.zig").Option;
pub const Tuning = @import("options.zig").Tuning;
pub const stats = @import("stats.zig");

/// Largest request `allocSmall` accepts (`MI_SMALL_SIZE_MAX`).
pub const small_size_max = 128 * @sizeOf(usize);

/// Alignment every block has without asking. Larger alignments take the `*_aligned` calls: a
/// small block is only naturally aligned up to a power of two of its size.
pub const word_alignment: Alignment = .fromByteUnits(@sizeOf(usize));

/// The linked mimalloc as `major * 10000 + minor * 100 + patch` (30600 is 3.6.0).
pub fn version() u32 {
    return @intCast(c.mi_version());
}

/// Frees memory from this allocator (null is fine), whichever heap or thread it came from.
pub fn free(ptr: ?*anyopaque) void {
    c.mi_free(ptr);
}

/// Frees a block with a shorter path, given the exact size and alignment it was *allocated* with
/// (not a later `realloc`/`resize` size, and not a smaller size within the same block). mimalloc
/// treats `memory.len <= small_size_max` as "this block is in a small page"; a wrong size is
/// undefined behavior, which is why `allocator` and the heap allocators, whose `resize` and
/// `remap` can change the size, free with plain `free`.
pub fn freeSized(memory: []u8, alignment: Alignment) void {
    if (alignment.compare(.gt, word_alignment)) {
        c.mi_free_size_aligned(memory.ptr, memory.len, alignment.toByteUnits());
    } else {
        c.mi_free_size(memory.ptr, memory.len);
    }
}

/// How many bytes are usable at `ptr`, at least what was asked for. Zero for null.
pub fn usableSize(ptr: ?*const anyopaque) usize {
    return c.mi_usable_size(ptr);
}

/// The size mimalloc would really reserve for a request of `len` bytes.
pub fn goodSize(len: usize) usize {
    return c.mi_good_size(len);
}

/// Whether `ptr` lies in memory mimalloc manages. Not a validity check for a block.
pub fn isInHeapRegion(ptr: ?*const anyopaque) bool {
    return c.mi_is_in_heap_region(ptr);
}

/// Returns free memory to the OS (all of it when `force`).
pub fn collect(force: bool) void {
    c.mi_collect(force);
}

/// Prepares the calling thread. mimalloc does this lazily; call it on threads that start
/// outside the usual paths only if you see the first allocation stall.
pub fn threadInit() void {
    c.mi_thread_init();
}

/// Flushes the calling thread's state before a thread that mimalloc cannot see exit
/// (for example one created with raw `clone`) ends. Threads from std/pthreads need nothing.
pub fn threadDone() void {
    c.mi_thread_done();
}

pub const ProcessInfo = struct {
    elapsed_ms: usize,
    user_ms: usize,
    system_ms: usize,
    current_rss: usize,
    peak_rss: usize,
    current_commit: usize,
    peak_commit: usize,
    page_faults: usize,
};

/// Counters for the process as mimalloc sees it (a few are zero where the OS gives none).
pub fn processInfo() ProcessInfo {
    var info: ProcessInfo = undefined;
    c.mi_process_info(
        &info.elapsed_ms,
        &info.user_ms,
        &info.system_ms,
        &info.current_rss,
        &info.peak_rss,
        &info.current_commit,
        &info.peak_commit,
        &info.page_faults,
    );
    return info;
}

// ---- Allocation through the default (thread-local) heap ----

/// Uninitialized, `alignment`-aligned storage, or null on out-of-memory. Release with `free`
/// or `freeSized`.
pub fn alloc(len: usize, alignment: Alignment) ?[*]u8 {
    if (len <= small_size_max and alignment.compare(.lte, word_alignment)) return allocSmall(len);
    return @ptrCast(c.mi_malloc_aligned(len, alignment.toByteUnits()));
}

/// As `alloc`, zero-filled.
pub fn allocZeroed(len: usize, alignment: Alignment) ?[*]u8 {
    if (len <= small_size_max and alignment.compare(.lte, word_alignment)) {
        return @ptrCast(c.mi_zalloc_small(len));
    }
    return @ptrCast(c.mi_zalloc_aligned(len, alignment.toByteUnits()));
}

/// The short path for `len <= small_size_max` with at most `word_alignment`.
pub fn allocSmall(len: usize) ?[*]u8 {
    std.debug.assert(len <= small_size_max);
    return @ptrCast(c.mi_malloc_small(len));
}

/// Resizes in place if the block's capacity allows it, else moves it (contents preserved up to
/// the smaller size). On null the original block stays valid.
pub fn realloc(memory: []u8, new_len: usize, alignment: Alignment) ?[*]u8 {
    return @ptrCast(c.mi_realloc_aligned(memory.ptr, new_len, alignment.toByteUnits()));
}

/// Process-lifetime allocator over mimalloc. Blocks may be freed on any thread. No deinit.
pub const allocator: std.mem.Allocator = .{ .ptr = undefined, .vtable = &global_vtable };

const global_vtable: std.mem.Allocator.VTable = .{
    .alloc = globalAlloc,
    .resize = globalResize,
    .remap = globalRemap,
    .free = globalFree,
};

fn globalAlloc(_: *anyopaque, len: usize, alignment: Alignment, _: usize) ?[*]u8 {
    return alloc(len, alignment);
}

fn globalResize(_: *anyopaque, memory: []u8, _: Alignment, new_len: usize, _: usize) bool {
    return new_len <= usableSize(memory.ptr);
}

fn globalRemap(_: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, _: usize) ?[*]u8 {
    if (new_len <= usableSize(memory.ptr)) return memory.ptr;
    return realloc(memory, new_len, alignment);
}

fn globalFree(_: *anyopaque, memory: []u8, _: Alignment, _: usize) void {
    free(memory.ptr);
}

/// A `std.mem.Allocator` vtable for an owner type with `allocBytes(self, len, alignment) ?[*]u8`
/// and `reallocBytes(self, memory, new_len, alignment) ?[*]u8`. Resizing in place is by usable
/// size, as for `allocator`.
fn OwnedVTable(comptime Owner: type) type {
    return struct {
        const vtable: std.mem.Allocator.VTable = .{
            .alloc = allocFn,
            .resize = resizeFn,
            .remap = remapFn,
            .free = freeFn,
        };

        fn allocFn(ctx: *anyopaque, len: usize, alignment: Alignment, _: usize) ?[*]u8 {
            const owner: *Owner = @ptrCast(@alignCast(ctx));
            return owner.allocBytes(len, alignment);
        }

        fn resizeFn(_: *anyopaque, memory: []u8, _: Alignment, new_len: usize, _: usize) bool {
            return new_len <= usableSize(memory.ptr);
        }

        fn remapFn(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, _: usize) ?[*]u8 {
            if (new_len <= usableSize(memory.ptr)) return memory.ptr;
            const owner: *Owner = @ptrCast(@alignCast(ctx));
            return owner.reallocBytes(memory, new_len, alignment);
        }

        fn freeFn(_: *anyopaque, memory: []u8, _: Alignment, _: usize) void {
            free(memory.ptr);
        }
    };
}

/// A mimalloc heap. Heaps are first-class in mimalloc 3: any thread may allocate from one and
/// any thread may free its blocks, so a `*Heap` is shareable (it still has one owner who
/// destroys it). Blocks of different heaps live in different pages, which makes `destroy`
/// a cheap way to free a whole group of allocations at once.
pub const Heap = opaque {
    pub const CreateError = error{OutOfMemory};

    /// A new heap over the process's memory. Release with `destroy` or `delete`.
    pub fn create() CreateError!*Heap {
        return c.mi_heap_new() orelse error.OutOfMemory;
    }

    /// A new heap that allocates only from `arena` (see `Arena.manage`).
    pub fn createInArena(arena: Arena.Id) CreateError!*Heap {
        return c.mi_heap_new_in_arena(arena) orelse error.OutOfMemory;
    }

    /// The heap the process's `malloc`-style calls use. Never destroy it.
    pub fn main() *Heap {
        return c.mi_heap_main();
    }

    /// The heap that owns the block at `ptr`, or null for memory mimalloc does not manage.
    pub fn owner(ptr: *const anyopaque) ?*Heap {
        return c.mi_heap_of(ptr);
    }

    /// Frees every block of the heap, live or not, and the heap itself. All its pointers become
    /// invalid; no thread may use it afterwards.
    pub fn destroy(heap: *Heap) void {
        c.mi_heap_destroy(heap);
    }

    /// Hands the live blocks to the main heap (they stay valid and are freed one by one) and
    /// releases the heap.
    pub fn delete(heap: *Heap) void {
        c.mi_heap_delete(heap);
    }

    /// Returns free pages of this heap to the OS (all of them when `force`).
    pub fn collect(heap: *Heap, force: bool) void {
        c.mi_heap_collect(heap, force);
    }

    pub fn contains(heap: *const Heap, ptr: *const anyopaque) bool {
        return c.mi_heap_contains(heap, ptr);
    }

    /// This thread's theap for the heap, created on first use. Only this thread may use it.
    pub fn theap(heap: *Heap) *Theap {
        return c.mi_heap_theap(heap);
    }

    /// Uninitialized, `alignment`-aligned storage from this heap, or null on out-of-memory.
    /// Release with `free`/`freeSized` (from any thread) or `destroy`.
    pub fn alloc(heap: *Heap, len: usize, alignment: Alignment) ?[*]u8 {
        if (len <= small_size_max and alignment.compare(.lte, word_alignment)) {
            return @ptrCast(c.mi_heap_malloc_small(heap, len));
        }
        return @ptrCast(c.mi_heap_malloc_aligned(heap, len, alignment.toByteUnits()));
    }

    /// As `alloc`, zero-filled.
    pub fn allocZeroed(heap: *Heap, len: usize, alignment: Alignment) ?[*]u8 {
        if (alignment.compare(.lte, word_alignment)) return @ptrCast(c.mi_heap_zalloc(heap, len));
        return @ptrCast(c.mi_heap_zalloc_aligned(heap, len, alignment.toByteUnits()));
    }

    /// Grows or shrinks a block of this heap; null leaves it valid.
    pub fn realloc(heap: *Heap, memory: []u8, new_len: usize, alignment: Alignment) ?[*]u8 {
        return @ptrCast(c.mi_heap_realloc_aligned(heap, memory.ptr, new_len, alignment.toByteUnits()));
    }

    fn allocBytes(heap: *Heap, len: usize, alignment: Alignment) ?[*]u8 {
        return heap.alloc(len, alignment);
    }

    fn reallocBytes(heap: *Heap, memory: []u8, new_len: usize, alignment: Alignment) ?[*]u8 {
        return heap.realloc(memory, new_len, alignment);
    }

    /// An allocator over this heap. It borrows the heap, which must outlive every use; freeing
    /// is optional when the heap is `destroy`ed. Safe to share between threads.
    pub fn allocator(heap: *Heap) std.mem.Allocator {
        return .{ .ptr = heap, .vtable = &OwnedVTable(Heap).vtable };
    }
};

/// The thread-local part of a heap. Allocating through one skips the thread-local lookup the
/// plain functions do, which pays off for a runtime that already carries per-thread state.
/// Only the thread that obtained it may allocate through it (blocks are freed from anywhere).
pub const Theap = opaque {
    /// The calling thread's default theap: fetch it once per thread and keep it.
    pub fn default() *Theap {
        return c.mi_theap_get_default();
    }

    /// Makes `theap` the calling thread's default and returns the previous one.
    pub fn setDefault(theap: *Theap) *Theap {
        return c.mi_theap_set_default(theap);
    }

    pub fn collect(theap: *Theap, force: bool) void {
        c.mi_theap_collect(theap, force);
    }

    /// Uninitialized, `alignment`-aligned storage, or null on out-of-memory.
    pub fn alloc(theap: *Theap, len: usize, alignment: Alignment) ?[*]u8 {
        if (alignment.compare(.lte, word_alignment)) {
            if (len <= small_size_max) return @ptrCast(c.mi_theap_malloc_small(theap, len));
            return @ptrCast(c.mi_theap_malloc(theap, len));
        }
        return @ptrCast(c.mi_theap_malloc_aligned(theap, len, alignment.toByteUnits()));
    }

    /// As `alloc`, zero-filled.
    pub fn allocZeroed(theap: *Theap, len: usize, alignment: Alignment) ?[*]u8 {
        if (alignment.compare(.lte, word_alignment)) {
            if (len <= small_size_max) return @ptrCast(c.mi_theap_zalloc_small(theap, len));
            return @ptrCast(c.mi_theap_zalloc(theap, len));
        }
        return @ptrCast(c.mi_theap_zalloc_aligned(theap, len, alignment.toByteUnits()));
    }

    pub fn realloc(theap: *Theap, memory: []u8, new_len: usize, _: Alignment) ?[*]u8 {
        return @ptrCast(c.mi_theap_realloc(theap, memory.ptr, new_len));
    }

    fn allocBytes(theap: *Theap, len: usize, alignment: Alignment) ?[*]u8 {
        return theap.alloc(len, alignment);
    }

    fn reallocBytes(theap: *Theap, memory: []u8, new_len: usize, alignment: Alignment) ?[*]u8 {
        return theap.realloc(memory, new_len, alignment);
    }

    /// An allocator over this theap, for use on the owning thread only.
    pub fn allocator(theap: *Theap) std.mem.Allocator {
        return .{ .ptr = theap, .vtable = &OwnedVTable(Theap).vtable };
    }
};

/// Memory mimalloc allocates from beyond its own OS requests: reserved up front, huge pages, or
/// a range someone else owns (for example pages inside the V8 sandbox).
pub const Arena = struct {
    /// mimalloc's `mi_arena_id_t`; `none` is the null id.
    pub const Id = enum(usize) {
        none = 0,
        _,

        /// Whether `ptr` points into this arena.
        pub fn contains(id: Id, ptr: *const anyopaque) bool {
            return c.mi_arena_contains(id, ptr);
        }

        /// The arena's whole range.
        pub fn area(id: Id) []u8 {
            var size: usize = 0;
            const start: [*]u8 = @ptrCast(c.mi_arena_area(id, &size) orelse return &.{});
            return start[0..size];
        }

        /// Takes the arena out of mimalloc so its range may be unmapped (needs the
        /// `0001-enable-arena-unload` patch). Destroy every heap made in it and free every block
        /// first. mimalloc keeps the arena's metadata inside the range, so skipping this before
        /// unmapping leaves it visiting freed memory.
        pub fn unload(id: Id) error{NotUnloadable}!void {
            if (!c.mi_arena_unload(id, null, null, null)) return error.NotUnloadable;
        }
    };

    pub const ManageOptions = struct {
        /// The range is already committed (readable and writable).
        committed: bool = false,
        /// mimalloc must never decommit or reset it.
        pinned: bool = false,
        /// The range is known to be zero-filled.
        zeroed: bool = false,
        /// NUMA node, or -1 for none.
        numa_node: i32 = -1,
        /// Only heaps made for this arena (`Heap.createInArena`) allocate from it.
        exclusive: bool = true,
    };

    /// Hands `range` to mimalloc. It must be aligned to `minAlignment`, at least `minSize`
    /// bytes, and at most 16 GiB for `unload` to work. The memory must outlive the arena.
    pub fn manage(range: []u8, options: ManageOptions) error{NotManageable}!Id {
        var id: Id = .none;
        if (!c.mi_manage_os_memory_ex(range.ptr, range.len, options.committed, options.pinned, options.zeroed, options.numa_node, options.exclusive, &id)) {
            return error.NotManageable;
        }
        return id;
    }

    /// Reserves `size` bytes of OS memory as a (shared) arena.
    pub fn reserve(size: usize, options: struct { commit: bool = false, allow_large: bool = false }) error{OutOfMemory}!void {
        if (c.mi_reserve_os_memory(size, options.commit, options.allow_large) != 0) return error.OutOfMemory;
    }

    /// Reserves `pages` 1 GiB huge pages on `numa_node` (-1 for any), waiting at most
    /// `timeout_ms` (0 for no limit). Linux only.
    pub fn reserveHugePages(pages: usize, numa_node: i32, timeout_ms: usize) error{OutOfMemory}!void {
        if (c.mi_reserve_huge_os_pages_at(pages, numa_node, timeout_ms) != 0) return error.OutOfMemory;
    }

    /// Alignment a managed range must have.
    pub fn minAlignment() usize {
        return c.mi_arena_min_alignment();
    }

    /// Smallest managed range.
    pub fn minSize() usize {
        return c.mi_arena_min_size();
    }

    /// Largest block an arena serves; bigger requests go to the OS.
    pub fn maxObjectSize() usize {
        return c.mi_arena_max_object_size();
    }

    /// Purges free arena memory to the OS now.
    pub fn purge() void {
        c.mi_arenas_purge();
    }
};

test {
    _ = @import("options.zig");
    _ = @import("stats.zig");
}

test "version is 3.6.0" {
    try std.testing.expectEqual(@as(u32, 30600), version());
}

test "aligned allocation, realloc preservation and zero-size allocation" {
    var memory = try allocator.alignedAlloc(u8, .fromByteUnits(4096), 31);
    defer allocator.free(memory);
    @memset(memory, 0x5a);
    memory = try allocator.realloc(memory, 1024 * 1024);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(memory.ptr) % 4096);
    const expected: [31]u8 = @splat(0x5a);
    try std.testing.expectEqualSlices(u8, &expected, memory[0..31]);
    const empty = try allocator.alloc(u8, 0);
    defer allocator.free(empty);
}

test "small, zeroed and sized paths" {
    const small = alloc(100, .@"1").?[0..100];
    @memset(small, 0xff);
    freeSized(small, .@"1");
    const zeroed = allocZeroed(small_size_max, .@"8").?[0..small_size_max];
    try std.testing.expectEqualSlices(u8, &@as([small_size_max]u8, @splat(0)), zeroed);
    freeSized(zeroed, .@"8");
    const aligned = allocZeroed(100, .@"64").?[0..100];
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(aligned.ptr) % 64);
    freeSized(aligned, .@"64");
    try std.testing.expect(goodSize(100) >= 100);
    try std.testing.expect(usableSize(null) == 0);
}

test "blocks can be freed from a different thread" {
    const memory = try allocator.alloc(u8, 4096);
    @memset(memory, 0x5a);
    const Worker = struct {
        fn run(m: []u8) void {
            allocator.free(m);
        }
    };
    const worker = std.Thread.spawn(.{}, Worker.run, .{memory}) catch |err| {
        allocator.free(memory);
        return err;
    };
    worker.join();
}

test "heap allocator, ownership and destroy" {
    const heap = try Heap.create();
    defer heap.destroy();
    var list: std.ArrayList(u64) = .empty;
    for (0..1000) |i| try list.append(heap.allocator(), i);
    try std.testing.expectEqual(@as(u64, 999), list.items[999]);
    try std.testing.expect(heap.contains(list.items.ptr));
    try std.testing.expectEqual(heap, Heap.owner(list.items.ptr).?);
    const zeroed = heap.allocZeroed(300, .@"16").?[0..300];
    try std.testing.expectEqualSlices(u8, &@as([300]u8, @splat(0)), zeroed);
    heap.collect(false);
}

test "theap allocation matches the plain path" {
    const theap = Theap.default();
    const a = theap.alloc(64, .@"8").?[0..64];
    const b = theap.allocZeroed(5000, .@"32").?[0..5000];
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(b.ptr) % 32);
    try std.testing.expectEqualSlices(u8, &@as([5000]u8, @splat(0)), b);
    free(a.ptr);
    free(b.ptr);
    const gpa = theap.allocator();
    const list = try gpa.alloc(u32, 100);
    defer gpa.free(list);
}

test "process info reports resident memory" {
    const info = processInfo();
    try std.testing.expect(info.current_rss > 0 or info.current_commit > 0);
}
