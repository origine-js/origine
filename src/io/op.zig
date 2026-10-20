//! Caller-owned operation record shared by the Zig and C APIs (`extern`, layout is ABI).
//! An Op must stay alive and unmoved from submit until its callback runs. It holds plain data
//! only; never put engine handles in it.
//! CONTRACT (docs/contracts.md, surface A): `Kind`, `O`, `FallocFlags`, `Stat`, `Iovec` and `Op` mirror
//! include/origine_io.h and are checked against it by contract_test.zig.
const std = @import("std");

pub const Fd = isize;
/// Directory descriptor meaning "relative to the current directory" for path operations.
pub const fd_cwd: Fd = -1;

pub const Kind = enum(i32) {
    nop = 0,
    open = 1,
    close = 2,
    read = 3,
    write = 4,
    fstat = 5,
    mkdir = 6,
    unlink = 7,
    rename = 8,
    timeout = 9,
    /// flags bit0: data only (fdatasync).
    fsync = 10,
    /// fd = out, fd2 = in, offset = in offset (-1 = current), len = count; result = bytes.
    sendfile = 11,
    /// offset, len; aux = FallocFlags.
    fallocate = 12,
    /// socket: buf, len, flags = native MSG_*; result = bytes.
    send = 13,
    recv = 14,
    /// buf = native `struct msghdr *`, flags = native MSG_*.
    sendmsg = 15,
    recvmsg = 16,
    /// buf = `*u32` address, aux = expected value; completes 0 when woken, -EAGAIN if the
    /// value differed, -ETIMEDOUT if `offset >= 0` nanoseconds elapsed first.
    futex_wait = 17,
    /// buf = `*u32` address, aux = max waiters to wake; result = number woken.
    futex_wake = 18,
    /// Path stat (fstatat): fd = dir, path; flags bit0: do not follow symlinks. Writes `Stat` to buf.
    stat = 19,
    /// fd = socket, buf = native `sockaddr *`, len = its size.
    connect = 20,
    /// fd = listening socket; buf = optional native `sockaddr *` out, len = its capacity (the
    /// peer address size is written back into `aux`); flags bit0: close-on-exec is always set.
    /// result = new fd.
    accept = 21,
    /// linkat: fd/path = existing, fd2/path2 = new name.
    link = 22,
    /// buf = `*const Iovec`, len = iovec count; offset -1 = current position, else preadv/pwritev.
    readv = 23,
    writev = 24,
    /// fd = directory, buf/len = output buffer, offset = cookie in (0 = start). Result = bytes
    /// written, 0 = end of directory, -ERANGE if the first entry does not fit (use >= 4096).
    /// On success the next cookie is written to `aux`. Entries are packed back to back, never
    /// split, "." and ".." skipped: `kind: u8` (0 other, 1 file, 2 dir, 3 symlink),
    /// `name_len: u16` little endian, then `name_len` name bytes (no NUL). The cookie is the
    /// directory fd position; do not run two readdirs on one fd at once.
    readdir = 25,
    /// fd, offset = new length (>= 0).
    ftruncate = 26,
    _,
};

/// Portable open flags (`aux` of an open op); the access mode is the low two bits.
pub const O = struct {
    pub const RDONLY: u64 = 0;
    pub const WRONLY: u64 = 1;
    pub const RDWR: u64 = 2;
    pub const CREAT: u64 = 0x100;
    pub const TRUNC: u64 = 0x200;
    pub const APPEND: u64 = 0x400;
    pub const EXCL: u64 = 0x800;
    pub const DIRECTORY: u64 = 0x1000;
};

/// Same layout as the platform `struct iovec`.
pub const Iovec = extern struct {
    base: ?*anyopaque,
    len: usize,
};

/// `aux` of a fallocate op.
pub const FallocFlags = struct {
    pub const KEEP_SIZE: u64 = 1;
};

pub const Stat = extern struct {
    size: u64,
    mode: u32,
    kind: u32, // 1 file, 2 directory, 3 symlink, 0 other
};

pub const Callback = *const fn (op: *Op, result: i64) callconv(.c) void;

/// `result` is a value >= 0 on success or `-errno` on failure (`-ECANCELED` when cancelled).
pub const Op = extern struct {
    cb: ?Callback = null,
    user: ?*anyopaque = null,
    kind: Kind = .nop,
    flags: u32 = 0,
    /// Subject descriptor; for open/mkdir/unlink/rename/link/stat the directory descriptor (`fd_cwd`).
    fd: Fd = fd_cwd,
    /// Second descriptor: sendfile input, or the new directory for rename/link (`fd_cwd`).
    fd2: Fd = fd_cwd,
    offset: i64 = -1,
    buf: ?*anyopaque = null,
    len: usize = 0,
    /// UTF-8; must outlive the op.
    path: ?[*:0]const u8 = null,
    path2: ?[*:0]const u8 = null,
    /// open: flags in `O` | mode << 32. timeout: nanoseconds.
    aux: u64 = 0,
    result: i64 = 0,
    /// Backend scratch. priv[0] is the intrusive queue link, priv[1] the backend state.
    priv: [8]?*anyopaque = @splat(null),
};

/// Intrusive FIFO through `priv[0]`. Not thread-safe.
pub const Queue = struct {
    head: ?*Op = null,
    tail: ?*Op = null,

    pub fn push(q: *Queue, op: *Op) void {
        op.priv[0] = null;
        if (q.tail) |t| t.priv[0] = op else q.head = op;
        q.tail = op;
    }

    pub fn pop(q: *Queue) ?*Op {
        const op = q.head orelse return null;
        q.head = nextOf(op);
        if (q.head == null) q.tail = null;
        op.priv[0] = null;
        return op;
    }

    /// Unlinks `target` if queued; linear.
    pub fn remove(q: *Queue, target: *Op) bool {
        var prev: ?*Op = null;
        var cur = q.head;
        while (cur) |c| : ({
            prev = c;
            cur = nextOf(c);
        }) {
            if (c != target) continue;
            const next = nextOf(c);
            if (prev) |p| p.priv[0] = next else q.head = next;
            if (q.tail == c) q.tail = prev;
            c.priv[0] = null;
            return true;
        }
        return false;
    }

    pub fn isEmpty(q: *const Queue) bool {
        return q.head == null;
    }

    pub fn nextOf(op: *Op) ?*Op {
        return @ptrCast(@alignCast(op.priv[0]));
    }
};
