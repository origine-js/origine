//! Backend vtable. A backend executes ops and reports completions; it never invokes callbacks.
//! `Loop` owns dispatch, so callbacks always run on the thread driving `Loop.run`.
const std = @import("std");
const op_mod = @import("op.zig");
const Op = op_mod.Op;

// CONTRACT (docs/contracts.md, surface A): `Kind`, `Options`, `Mode` and `Caps` mirror include/origine_io.h
// (checked by contract_test.zig).

pub const Kind = enum(u32) { auto = 0, uring = 1, kqueue_gcd = 2, iocp = 3, threaded = 4 };

pub const Options = extern struct {
    backend: u32 = 0,
    /// Queue depth hint (ring entries) or worker count for pooled backends; 0 = default.
    entries: u32 = 0,
};

pub const PostFn = *const fn (ud: ?*anyopaque) callconv(.c) void;

pub const PostNode = struct {
    next: ?*PostNode = null,
    func: PostFn,
    ud: ?*anyopaque,
};

/// What one `poll` collected, both lists in FIFO order.
pub const Drained = struct {
    done: op_mod.Queue = .{},
    posts_head: ?*PostNode = null,
    posts_tail: ?*PostNode = null,

    pub fn pushPost(d: *Drained, node: *PostNode) void {
        node.next = null;
        if (d.posts_tail) |t| t.next = node else d.posts_head = node;
        d.posts_tail = node;
    }
};

pub const Mode = enum(c_int) { once = 0, nowait = 1, until_idle = 2 };

pub const Caps = struct {
    pub const nop: u64 = 1 << 0;
    pub const file_io: u64 = 1 << 1;
    pub const timeout: u64 = 1 << 2;
    pub const cancel: u64 = 1 << 3;
    pub const pollable: u64 = 1 << 4;
    pub const vectored: u64 = 1 << 5; // readv/writev
    pub const sockets: u64 = 1 << 6; // send/recv/sendmsg/recvmsg/connect/accept
    pub const futex: u64 = 1 << 7;
    pub const sendfile: u64 = 1 << 8;
    pub const fallocate: u64 = 1 << 9;
    pub const link: u64 = 1 << 10;
    pub const sync: u64 = 1 << 11; // fsync
    pub const readdir: u64 = 1 << 12;
    pub const ftruncate: u64 = 1 << 13;
};

pub const VTable = struct {
    /// Called on the loop thread. Takes ownership of `op` until it is reported by `poll`.
    submit: *const fn (ctx: *anyopaque, op: *Op) anyerror!void,
    /// Loop thread. Returns true if the op will still complete (with -ECANCELED or its result).
    cancel: *const fn (ctx: *anyopaque, op: *Op) bool,
    /// Loop thread. Blocks when `block` until a completion, `wake`, `post`, or timer deadline.
    poll: *const fn (ctx: *anyopaque, block: bool, out: *Drained) void,
    /// Any thread.
    wake: *const fn (ctx: *anyopaque) void,
    /// Any thread.
    post: *const fn (ctx: *anyopaque, func: PostFn, ud: ?*anyopaque) anyerror!void,
    /// Pollable OS handle for embedding in a foreign loop, or -1.
    pollable: *const fn (ctx: *anyopaque) isize,
    caps: u64,
    /// Stops workers and completes everything outstanding (-ECANCELED) into `out`, then frees.
    destroy: *const fn (ctx: *anyopaque, out: *Drained) void,
};

pub const Backend = struct {
    ctx: *anyopaque,
    vtable: *const VTable,
};
