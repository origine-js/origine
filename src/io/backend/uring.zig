//! Linux io_uring backend (std.os.linux.IoUring, no liburing).
//!
//! The ring is owned by the loop thread; `submit`/`cancel`/`poll`/`destroy` are loop-thread only and
//! take no locks. Only `wake` and `post` are thread-safe: `wake` writes an eventfd that a re-armed
//! read SQE watches, `post` pushes onto a lock-free MPSC stack and then wakes.
//!
//! Other operating systems can still `@import` this file: everything real lives in `Impl`, which
//! is never analyzed unless `supported` is true.
const std = @import("std");
const builtin = @import("builtin");
const op_mod = @import("../op.zig");
const backend = @import("../backend.zig");
const Op = op_mod.Op;

pub const supported = builtin.os.tag == .linux;

/// Caps every io_uring backend reports. `futex` is added per instance only when the kernel probe
/// (IORING_REGISTER_PROBE) lists IORING_OP_FUTEX_WAIT/WAKE (Linux >= 6.7), `ftruncate` likewise for
/// IORING_OP_FTRUNCATE (Linux >= 6.9). `readdir` runs on a small helper thread pool (no opcode).
pub const caps: u64 = backend.Caps.nop | backend.Caps.file_io | backend.Caps.timeout |
    backend.Caps.cancel | backend.Caps.pollable | backend.Caps.vectored | backend.Caps.sockets |
    backend.Caps.sendfile | backend.Caps.fallocate | backend.Caps.link | backend.Caps.sync |
    backend.Caps.readdir;

/// `allocator` is used on the loop thread only; post nodes come from std.heap.c_allocator.
pub fn create(allocator: std.mem.Allocator, opts: backend.Options) !backend.Backend {
    if (comptime !supported) return error.Unsupported;
    return Impl.create(allocator, opts);
}

const Impl = if (supported) struct {
    const linux = std.os.linux;
    const IoUring = linux.IoUring;

    /// user_data tags; real ops are pointers (aligned), so small integers never collide.
    /// A real op's user_data is its pointer, optionally with bit 0 set (`stage_timeout`) for the
    /// IORING_OP_LINK_TIMEOUT SQE that guards a futex_wait.
    const tag_wake: u64 = 1;
    const tag_cancel: u64 = 2;
    const stage_timeout: u64 = 1;
    comptime {
        if (@alignOf(Op) < 2) @compileError("user_data tagging needs Op alignment >= 2");
    }

    // Per-op scratch use (priv[0] is the Queue link, owned by op_mod.Queue / Drained):
    //   priv[1] -> heap Statx (fstat/stat), heap Sendfile (sendfile), mark (futex_wait: timed out)
    //   priv[2..3] -> kernel_timespec (timeout, futex_wait timeout); u32 socklen (accept)
    //   priv[4] -> next outstanding op        priv[5] -> prev outstanding op
    //   priv[6] = CQEs still expected (futex_wait: 1 or 2); readdir: state (rd_queued/running/canceled)
    //   readdir: priv[1] = next in the request queue, priv[3] = next in the done stack
    //   priv[7] != null while the kernel owns the op
    const p_extra = 1;
    const p_rdnext = 1;
    const p_rddone = 3;
    const p_ts = 2;
    const p_next = 4;
    const p_prev = 5;
    const p_pend = 6;
    const p_live = 7;

    // futex2 flags in sqe.fd: FUTEX2_SIZE_U32 | FUTEX2_PRIVATE (same flavor as std.Thread.Futex).
    const futex_flags: i32 = 0x02 | 0x80;
    const futex_match_any: u64 = 0xffff_ffff;

    /// Progress of a sendfile op: in -> pipe ("fill"), then pipe -> out ("drain"), repeated.
    const Sendfile = struct {
        rfd: i32,
        wfd: i32,
        chunk: usize,
        remaining: usize,
        total: usize = 0,
        /// Next offset in the input file, or -1 to use its current position.
        in_off: i64,
        /// Bytes sitting in the pipe.
        pending: usize = 0,
        draining: bool = false,
        /// Set by `cancel`: the next stage is not queued, so a cancel that raced a
        /// stage completion (and found nothing to cancel) is not lost.
        cancel_requested: bool = false,
    };
    /// Largest single read/write/send/recv: SQE lengths are u32, and the kernel caps transfers near
    /// this anyway. A short count is a legal result for all four.
    const max_io: usize = 0x7ffff000;
    const live_mark: ?*anyopaque = @ptrFromInt(1);

    const rd_queued: usize = 0;
    const rd_running: usize = 1;
    const rd_canceled: usize = 2;
    const rd_max_workers = 4;
    const rd_scratch = 16 * 1024;

    const State = struct {
        allocator: std.mem.Allocator,
        ring: IoUring,
        efd: linux.fd_t,
        efd_buf: u64 = 0,
        efd_armed: bool = false,
        /// Outstanding ops (doubly linked through priv[4]/priv[5]).
        live_head: ?*Op = null,
        inflight: usize = 0,
        /// MPSC stack of posted nodes (newest first). Producers CAS, consumer swaps to null.
        posts: ?*backend.PostNode = null,
        has_futex: bool = false,
        has_ftruncate: bool = false,
        // ---- readdir helper pool ----
        /// Spinlock guarding the request FIFO (rd_head/rd_tail).
        rd_lock: u32 = 0,
        rd_head: ?*Op = null,
        rd_tail: ?*Op = null,
        /// Counting eventfd (EFD_SEMAPHORE) the workers block on; -1 until the first readdir.
        rd_efd: linux.fd_t = -1,
        rd_closing: bool = false,
        /// MPSC stack of finished readdir ops (workers push, poll swaps).
        rd_done: ?*Op = null,
        rd_threads: [rd_max_workers]?std.Thread = @splat(null),
        rd_nthreads: usize = 0,
        /// Readdir ops submitted and not yet drained by poll (loop thread only).
        rd_outstanding: usize = 0,
        /// Set by destroy: multi-step ops stop continuing and complete as canceled.
        closing: bool = false,
        vt: backend.VTable = undefined,
    };

    const base_vtable: backend.VTable = .{
        .submit = submit,
        .cancel = cancel,
        .poll = poll,
        .wake = wake,
        .post = post,
        .pollable = pollable,
        .caps = caps,
        .destroy = destroy,
    };

    fn st(ctx: *anyopaque) *State {
        return @ptrCast(@alignCast(ctx));
    }

    fn create(allocator: std.mem.Allocator, opts: backend.Options) !backend.Backend {
        const want: u32 = if (opts.entries == 0) 256 else @min(opts.entries, 32768);
        const entries: u16 = @intCast(std.math.ceilPowerOfTwoAssert(u32, @max(want, 2)));

        const s = try allocator.create(State);
        errdefer allocator.destroy(s);

        // COOP_TASKRUN (5.19): completions run as task_work the next time this thread enters the
        // kernel instead of interrupting it with an IPI (uSockets' io_uring loop sets the same
        // flags). TASKRUN_FLAG makes the kernel flag pending work so `reap` can ask for it.
        // Older kernels reject the flags with EINVAL: fall back to a plain ring.
        const coop = linux.IORING_SETUP_COOP_TASKRUN | linux.IORING_SETUP_TASKRUN_FLAG;
        var ring = IoUring.init(entries, coop) catch try IoUring.init(entries, 0);
        errdefer ring.deinit();

        const r = linux.eventfd(0, linux.EFD.CLOEXEC);
        if (linux.errno(r) != .SUCCESS) return error.SystemResources;
        const efd: linux.fd_t = @intCast(r);
        errdefer _ = linux.close(efd);

        s.* = .{ .allocator = allocator, .ring = ring, .efd = efd };
        if (s.ring.get_probe()) |probe| {
            s.has_futex = probe.is_supported(.FUTEX_WAIT) and probe.is_supported(.FUTEX_WAKE);
            s.has_ftruncate = probe.is_supported(.FTRUNCATE);
        } else |_| {}
        s.vt = base_vtable;
        if (s.has_futex) s.vt.caps |= backend.Caps.futex;
        if (s.has_ftruncate) s.vt.caps |= backend.Caps.ftruncate;
        try armWake(s);
        return .{ .ctx = s, .vtable = &s.vt };
    }

    // ---- SQE helpers -------------------------------------------------------------------

    fn getSqe(s: *State) !*linux.io_uring_sqe {
        return s.ring.get_sqe() catch {
            // SQ full: hand what is queued to the kernel and retry once.
            _ = s.ring.submit() catch {};
            return s.ring.get_sqe();
        };
    }

    fn armWake(s: *State) !void {
        const sqe = try getSqe(s);
        sqe.prep_read(s.efd, std.mem.asBytes(&s.efd_buf), 0);
        sqe.user_data = tag_wake;
        s.efd_armed = true;
    }

    fn dirFd(fd: op_mod.Fd) linux.fd_t {
        return if (fd == op_mod.fd_cwd) linux.AT.FDCWD else @intCast(fd);
    }

    fn translateOpen(aux: u64) linux.O {
        var o: linux.O = .{ .CLOEXEC = true };
        o.ACCMODE = switch (aux & 3) {
            0 => .RDONLY,
            1 => .WRONLY,
            else => .RDWR,
        };
        if (aux & op_mod.O.CREAT != 0) o.CREAT = true;
        if (aux & op_mod.O.TRUNC != 0) o.TRUNC = true;
        if (aux & op_mod.O.APPEND != 0) o.APPEND = true;
        if (aux & op_mod.O.EXCL != 0) o.EXCL = true;
        if (aux & op_mod.O.DIRECTORY != 0) o.DIRECTORY = true;
        return o;
    }

    fn tsOf(op: *Op) *linux.kernel_timespec {
        return @ptrCast(@alignCast(&op.priv[p_ts]));
    }

    fn socklenOf(op: *Op) *u32 {
        return @ptrCast(@alignCast(&op.priv[p_ts]));
    }

    fn errno(e: linux.E) i64 {
        return -@as(i64, @backingInt(e));
    }

    /// Guarantees `n` free SQ slots without splitting a linked pair across a submit boundary.
    fn ensureSpace(s: *State, n: u32) !void {
        if (s.ring.sq.sqes.len - s.ring.sq_ready() < n) _ = s.ring.submit() catch {};
        if (s.ring.sq.sqes.len - s.ring.sq_ready() < n) return error.SystemResources;
    }

    fn sfOf(op: *Op) ?*Sendfile {
        return @ptrCast(@alignCast(op.priv[p_extra]));
    }

    fn sfFillSqe(s: *State, op: *Op, sf: *Sendfile) !void {
        const sqe = try getSqe(s);
        const off: u64 = @bitCast(sf.in_off); // -1 = current position
        sqe.prep_splice(@intCast(op.fd2), off, sf.wfd, std.math.maxInt(u64), @min(sf.remaining, sf.chunk));
        sqe.user_data = @intFromPtr(op);
    }

    fn sfDrainSqe(s: *State, op: *Op, sf: *Sendfile) !void {
        const sqe = try getSqe(s);
        sqe.prep_splice(sf.rfd, std.math.maxInt(u64), @intCast(op.fd), std.math.maxInt(u64), sf.pending);
        sqe.user_data = @intFromPtr(op);
    }

    // ---- outstanding list --------------------------------------------------------------

    fn link(s: *State, op: *Op) void {
        op.priv[p_prev] = null;
        op.priv[p_next] = s.live_head;
        if (s.live_head) |h| h.priv[p_prev] = op;
        s.live_head = op;
        op.priv[p_live] = live_mark;
        s.inflight += 1;
    }

    fn unlink(s: *State, op: *Op) void {
        const next: ?*Op = @ptrCast(@alignCast(op.priv[p_next]));
        const prev: ?*Op = @ptrCast(@alignCast(op.priv[p_prev]));
        if (prev) |p| p.priv[p_next] = next else s.live_head = next;
        if (next) |n| n.priv[p_prev] = prev;
        op.priv[p_next] = null;
        op.priv[p_prev] = null;
        op.priv[p_live] = null;
        s.inflight -= 1;
    }

    // ---- readdir helper pool -------------------------------------------------------------

    fn rdLock(s: *State) void {
        while (@cmpxchgWeak(u32, &s.rd_lock, 0, 1, .acquire, .monotonic) != null) {
            if (linux.sched_yield() != 0) std.atomic.spinLoopHint();
        }
    }

    fn rdUnlock(s: *State) void {
        @atomicStore(u32, &s.rd_lock, 0, .release);
    }

    fn rdState(op: *Op) *usize {
        return @ptrCast(&op.priv[p_pend]);
    }

    fn rdPop(s: *State) ?*Op {
        rdLock(s);
        defer rdUnlock(s);
        const op = s.rd_head orelse return null;
        s.rd_head = @ptrCast(@alignCast(op.priv[p_rdnext]));
        if (s.rd_head == null) s.rd_tail = null;
        op.priv[p_rdnext] = null;
        return op;
    }

    fn rdSubmit(s: *State, op: *Op) !void {
        if (s.rd_efd < 0) {
            const r = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.SEMAPHORE);
            if (linux.errno(r) != .SUCCESS) return error.SystemResources;
            s.rd_efd = @intCast(r);
        }
        // Grow the pool on demand (up to rd_max_workers) while requests outnumber workers.
        if (s.rd_nthreads == 0 or (s.rd_outstanding >= s.rd_nthreads and s.rd_nthreads < rd_max_workers)) {
            if (std.Thread.spawn(.{}, rdWorker, .{s})) |t| {
                s.rd_threads[s.rd_nthreads] = t;
                s.rd_nthreads += 1;
            } else |_| {
                if (s.rd_nthreads == 0) return error.SystemResources;
            }
        }
        rdState(op).* = rd_queued;
        op.priv[p_rdnext] = null;
        rdLock(s);
        if (s.rd_tail) |t| t.priv[p_rdnext] = op else s.rd_head = op;
        s.rd_tail = op;
        rdUnlock(s);
        const one: u64 = 1;
        _ = linux.write(s.rd_efd, std.mem.asBytes(&one), 8);
    }

    fn rdFinish(s: *State, op: *Op, res: i64) void {
        op.result = res;
        var head = @atomicLoad(?*Op, &s.rd_done, .monotonic);
        while (true) {
            op.priv[p_rddone] = head;
            head = @cmpxchgWeak(?*Op, &s.rd_done, head, op, .release, .monotonic) orelse break;
        }
        wake(@ptrCast(s));
    }

    fn rdWorker(s: *State) void {
        while (true) {
            var tok: u64 = 0;
            const r = linux.read(s.rd_efd, std.mem.asBytes(&tok), 8);
            if (linux.errno(r) == .INTR) continue;
            while (rdPop(s)) |op| {
                const closing = @atomicLoad(bool, &s.rd_closing, .acquire);
                if (closing or @cmpxchgStrong(usize, rdState(op), rd_queued, rd_running, .acq_rel, .acquire) != null) {
                    rdFinish(s, op, errno(.CANCELED));
                } else {
                    rdFinish(s, op, rdRun(op));
                }
            }
            if (@atomicLoad(bool, &s.rd_closing, .acquire)) return;
        }
    }

    fn rdKind(dfd: linux.fd_t, name: [*:0]const u8, dt: u8) u8 {
        var t = dt;
        if (t == linux.DT.UNKNOWN) {
            var sx: linux.Statx = undefined;
            if (linux.errno(linux.statx(dfd, name, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &sx)) != .SUCCESS) return 0;
            return switch (sx.mode & linux.S.IFMT) {
                linux.S.IFREG => 1,
                linux.S.IFDIR => 2,
                linux.S.IFLNK => 3,
                else => 0,
            };
        }
        t = switch (t) {
            linux.DT.REG => 1,
            linux.DT.DIR => 2,
            linux.DT.LNK => 3,
            else => 0,
        };
        return t;
    }

    /// lseek(cookie) + getdents64 + pack. Runs on a worker thread.
    fn rdRun(op: *Op) i64 {
        const dfd: linux.fd_t = @intCast(op.fd);
        const out: [*]u8 = @ptrCast(op.buf.?);
        const cap = op.len;
        var scratch: [rd_scratch]u8 align(8) = undefined;

        var r = linux.lseek(dfd, @bitCast(op.offset), 0);
        if (linux.errno(r) != .SUCCESS) return errno(linux.errno(r));

        var packed_n: usize = 0;
        var last_off: u64 = @intCast(op.offset);
        var full = false;
        while (!full) {
            const n = linux.getdents64(dfd, &scratch, scratch.len);
            if (linux.errno(n) != .SUCCESS) {
                if (packed_n > 0) break;
                return errno(linux.errno(n));
            }
            if (n == 0) break; // end of directory
            var pos: usize = 0;
            while (pos < n) {
                const d: *align(1) const linux.dirent64 = @ptrCast(&scratch[pos]);
                const name: [*:0]const u8 = @ptrCast(&scratch[pos + @offsetOf(linux.dirent64, "name")]);
                pos += d.reclen;
                const nl = std.mem.len(name);
                if (nl == 0 or (name[0] == '.' and (nl == 1 or (nl == 2 and name[1] == '.')))) {
                    last_off = d.off;
                    continue;
                }
                if (packed_n + 3 + nl > cap or nl > 0xffff) {
                    full = true;
                    break;
                }
                out[packed_n] = rdKind(dfd, name, d.type);
                out[packed_n + 1] = @truncate(nl);
                out[packed_n + 2] = @truncate(nl >> 8);
                @memcpy(out[packed_n + 3 ..][0..nl], name[0..nl]);
                packed_n += 3 + nl;
                last_off = d.off;
            }
            if (packed_n > 0) break;
        }
        if (full) {
            if (packed_n == 0) return errno(.RANGE);
            r = linux.lseek(dfd, @bitCast(last_off), 0);
            if (linux.errno(r) != .SUCCESS) return errno(linux.errno(r));
        }
        r = linux.lseek(dfd, 0, 1);
        if (linux.errno(r) != .SUCCESS) return errno(linux.errno(r));
        op.aux = r;
        return @intCast(packed_n);
    }

    /// Completes the readdir ops the workers have finished.
    fn drainRd(s: *State, out: *backend.Drained) void {
        if (s.rd_outstanding == 0) return;
        var stack = @atomicRmw(?*Op, &s.rd_done, .Xchg, null, .acquire);
        // Reverse so completions come out in finish order.
        var fifo: ?*Op = null;
        while (stack) |o| {
            stack = @ptrCast(@alignCast(o.priv[p_rddone]));
            o.priv[p_rddone] = fifo;
            fifo = o;
        }
        while (fifo) |o| {
            fifo = @ptrCast(@alignCast(o.priv[p_rddone]));
            o.priv[p_rddone] = null;
            s.rd_outstanding -= 1;
            completeWith(s, o, o.result, out);
        }
    }

    // ---- vtable ------------------------------------------------------------------------

    fn submit(ctx: *anyopaque, op: *Op) anyerror!void {
        const s = st(ctx);
        const ud: u64 = @intFromPtr(op);
        op.priv[p_extra] = null;
        op.priv[p_live] = null;

        switch (op.kind) {
            .nop => {
                const sqe = try getSqe(s);
                sqe.prep_nop();
                sqe.user_data = ud;
            },
            .open => {
                const path = op.path orelse return error.InvalidArgument;
                const sqe = try getSqe(s);
                sqe.prep_openat(dirFd(op.fd), path, translateOpen(op.aux), @intCast(op.aux >> 32));
                sqe.user_data = ud;
            },
            .close => {
                const sqe = try getSqe(s);
                sqe.prep_close(@intCast(op.fd));
                sqe.user_data = ud;
            },
            .fsync => {
                const sqe = try getSqe(s);
                sqe.prep_fsync(@intCast(op.fd), if (op.flags & 1 != 0) linux.IORING_FSYNC_DATASYNC else 0);
                sqe.user_data = ud;
            },
            .fallocate => {
                const sqe = try getSqe(s);
                const mode: i32 = if (op.aux & op_mod.FallocFlags.KEEP_SIZE != 0) 1 else 0; // FALLOC_FL_KEEP_SIZE
                sqe.prep_fallocate(@intCast(op.fd), mode, @bitCast(op.offset), op.len);
                sqe.user_data = ud;
            },
            .send, .recv => {
                const sqe = try getSqe(s);
                const ptr: [*]u8 = if (op.buf) |b| @ptrCast(b) else undefined;
                if (op.kind == .send)
                    sqe.prep_send(@intCast(op.fd), ptr[0..@min(op.len, max_io)], op.flags)
                else
                    sqe.prep_recv(@intCast(op.fd), ptr[0..@min(op.len, max_io)], op.flags);
                sqe.user_data = ud;
            },
            .sendmsg, .recvmsg => {
                const msg = op.buf orelse return error.InvalidArgument;
                const sqe = try getSqe(s);
                if (op.kind == .sendmsg)
                    sqe.prep_sendmsg(@intCast(op.fd), @ptrCast(@alignCast(msg)), op.flags)
                else
                    sqe.prep_recvmsg(@intCast(op.fd), @ptrCast(@alignCast(msg)), op.flags);
                sqe.user_data = ud;
            },
            .connect => {
                const addr = op.buf orelse return error.InvalidArgument;
                const sqe = try getSqe(s);
                sqe.prep_connect(@intCast(op.fd), @ptrCast(@alignCast(addr)), @intCast(op.len));
                sqe.user_data = ud;
            },
            .accept => {
                const sqe = try getSqe(s);
                if (op.buf) |a| {
                    socklenOf(op).* = @intCast(op.len);
                    sqe.prep_accept(@intCast(op.fd), @ptrCast(@alignCast(a)), socklenOf(op), linux.SOCK.CLOEXEC);
                } else {
                    sqe.prep_accept(@intCast(op.fd), null, null, linux.SOCK.CLOEXEC);
                }
                sqe.user_data = ud;
            },
            .link => {
                const from = op.path orelse return error.InvalidArgument;
                const to = op.path2 orelse return error.InvalidArgument;
                const sqe = try getSqe(s);
                sqe.prep_linkat(dirFd(op.fd), from, dirFd(op.fd2), to, 0);
                sqe.user_data = ud;
            },
            .readv, .writev => {
                const iov: [*]const std.posix.iovec = if (op.buf) |b| @ptrCast(@alignCast(b)) else return error.InvalidArgument;
                const sqe = try getSqe(s);
                const off: u64 = @bitCast(op.offset); // -1 => current file position
                if (op.kind == .readv)
                    sqe.prep_readv(@intCast(op.fd), iov[0..op.len], off)
                else
                    sqe.prep_writev(@intCast(op.fd), @ptrCast(iov[0..op.len]), off);
                sqe.user_data = ud;
            },
            .stat => {
                _ = op.buf orelse return error.InvalidArgument;
                const path = op.path orelse return error.InvalidArgument;
                const sx = try s.allocator.create(linux.Statx);
                errdefer s.allocator.destroy(sx);
                const sqe = try getSqe(s);
                const mask: linux.STATX = .{ .TYPE = true, .MODE = true, .SIZE = true };
                const fl: u32 = if (op.flags & 1 != 0) linux.AT.SYMLINK_NOFOLLOW else 0;
                sqe.prep_statx(dirFd(op.fd), path, fl, mask, sx);
                sqe.user_data = ud;
                op.priv[p_extra] = sx;
            },
            .futex_wait => {
                const addr = op.buf orelse return error.InvalidArgument;
                op.priv[p_pend] = @ptrFromInt(1);
                if (!s.has_futex) {
                    // Kernel without IORING_OP_FUTEX_*: a nop that `complete` turns into -ENOSYS.
                    const sqe = try getSqe(s);
                    sqe.prep_nop();
                    sqe.user_data = ud;
                } else if (op.offset >= 0) {
                    try ensureSpace(s, 2);
                    const ns: u64 = @intCast(op.offset);
                    const ts = tsOf(op);
                    ts.* = .{ .sec = @intCast(ns / std.time.ns_per_s), .nsec = @intCast(ns % std.time.ns_per_s) };
                    const sqe = try getSqe(s);
                    sqe.prep_rw(.FUTEX_WAIT, futex_flags, @intFromPtr(addr), 0, op.aux & 0xffff_ffff);
                    sqe.addr3 = futex_match_any;
                    sqe.flags |= linux.IOSQE_IO_LINK;
                    sqe.user_data = ud;
                    const tsqe = try getSqe(s);
                    tsqe.prep_link_timeout(ts, 0);
                    tsqe.user_data = ud | stage_timeout;
                    op.priv[p_pend] = @ptrFromInt(2);
                } else {
                    const sqe = try getSqe(s);
                    sqe.prep_rw(.FUTEX_WAIT, futex_flags, @intFromPtr(addr), 0, op.aux & 0xffff_ffff);
                    sqe.addr3 = futex_match_any;
                    sqe.user_data = ud;
                }
            },
            .futex_wake => {
                const addr = op.buf orelse return error.InvalidArgument;
                const sqe = try getSqe(s);
                if (s.has_futex) {
                    sqe.prep_rw(.FUTEX_WAKE, futex_flags, @intFromPtr(addr), 0, op.aux & 0xffff_ffff);
                    sqe.addr3 = futex_match_any;
                } else {
                    sqe.prep_nop();
                }
                sqe.user_data = ud;
            },
            .sendfile => {
                if (op.len == 0) {
                    const sqe = try getSqe(s);
                    sqe.prep_nop();
                    sqe.user_data = ud;
                } else {
                    var fds: [2]i32 = undefined;
                    if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return error.SystemResources;
                    errdefer {
                        _ = linux.close(fds[0]);
                        _ = linux.close(fds[1]);
                    }
                    // Best effort: a bigger pipe means fewer round trips (F_SETPIPE_SZ / F_GETPIPE_SZ).
                    _ = linux.fcntl(fds[1], 1031, 1 << 20);
                    const got = linux.fcntl(fds[1], 1032, 0);
                    const chunk: usize = if (linux.errno(got) == .SUCCESS and got > 0) got else 65536;
                    const sf = try s.allocator.create(Sendfile);
                    errdefer s.allocator.destroy(sf);
                    sf.* = .{ .rfd = fds[0], .wfd = fds[1], .chunk = chunk, .remaining = op.len, .in_off = op.offset };
                    try sfFillSqe(s, op, sf);
                    op.priv[p_extra] = sf;
                }
            },
            .read, .write => {
                const sqe = try getSqe(s);
                const off: u64 = @bitCast(op.offset); // -1 => current file position
                const ptr: [*]u8 = if (op.buf) |b| @ptrCast(b) else undefined;
                if (op.kind == .read)
                    sqe.prep_read(@intCast(op.fd), ptr[0..@min(op.len, max_io)], off)
                else
                    sqe.prep_write(@intCast(op.fd), ptr[0..@min(op.len, max_io)], off);
                sqe.user_data = ud;
            },
            .fstat => {
                const out = op.buf orelse return error.InvalidArgument;
                _ = out;
                const sx = try s.allocator.create(linux.Statx);
                errdefer s.allocator.destroy(sx);
                const sqe = try getSqe(s);
                const mask: linux.STATX = .{ .TYPE = true, .MODE = true, .SIZE = true };
                if (op.path) |p| {
                    sqe.prep_statx(dirFd(op.fd), p, 0, mask, sx);
                } else {
                    sqe.prep_statx(@intCast(op.fd), "", linux.AT.EMPTY_PATH, mask, sx);
                }
                sqe.user_data = ud;
                op.priv[p_extra] = sx;
            },
            .mkdir => {
                const path = op.path orelse return error.InvalidArgument;
                const mode: u32 = if (op.aux & 0xffff_ffff != 0) @intCast(op.aux & 0xffff_ffff) else 0o777;
                const sqe = try getSqe(s);
                sqe.prep_mkdirat(dirFd(op.fd), path, mode);
                sqe.user_data = ud;
            },
            .unlink => {
                const path = op.path orelse return error.InvalidArgument;
                const sqe = try getSqe(s);
                // flags bit 0: remove a directory (AT_REMOVEDIR)
                sqe.prep_unlinkat(dirFd(op.fd), path, if (op.flags & 1 != 0) linux.AT.REMOVEDIR else 0);
                sqe.user_data = ud;
            },
            .rename => {
                const from = op.path orelse return error.InvalidArgument;
                const to = op.path2 orelse return error.InvalidArgument;
                const sqe = try getSqe(s);
                sqe.prep_renameat(dirFd(op.fd), from, dirFd(op.fd2), to, 0);
                sqe.user_data = ud;
            },
            .ftruncate => {
                const sqe = try getSqe(s);
                if (s.has_ftruncate and op.offset >= 0) {
                    sqe.prep_rw(.FTRUNCATE, @intCast(op.fd), 0, 0, @intCast(op.offset));
                } else {
                    sqe.prep_nop(); // `complete` turns it into -ENOSYS / -EINVAL
                }
                sqe.user_data = ud;
            },
            .readdir => {
                _ = op.buf orelse return error.InvalidArgument;
                try rdSubmit(s, op);
                link(s, op);
                s.rd_outstanding += 1;
                return;
            },
            .timeout => {
                const ts = tsOf(op);
                ts.* = .{
                    .sec = @intCast(op.aux / std.time.ns_per_s),
                    .nsec = @intCast(op.aux % std.time.ns_per_s),
                };
                const sqe = try getSqe(s);
                sqe.prep_timeout(ts, 0, 0);
                sqe.user_data = ud;
            },
            else => return error.Unsupported,
        }
        link(s, op);
    }

    fn cancel(ctx: *anyopaque, op: *Op) bool {
        const s = st(ctx);
        if (op.priv[p_live] == null) return false;
        if (op.kind == .readdir) {
            // Queued: mark it, a worker completes it as -ECANCELED. Running: finishes normally.
            _ = @cmpxchgStrong(usize, @as(*usize, @ptrCast(&op.priv[p_pend])), rd_queued, rd_canceled, .acq_rel, .acquire);
            return true;
        }
        if (op.kind == .sendfile) {
            if (sfOf(op)) |sf| sf.cancel_requested = true;
        }
        // The caller may close the descriptor right after this returns. SQEs not yet submitted
        // would then run against a closed (or reused) fd number, so hand them to the kernel
        // first: an issued op keeps its own file reference and the cancel below reaches it.
        _ = s.ring.submit() catch {};
        const sqe = getSqe(s) catch return false;
        sqe.prep_cancel(@intFromPtr(op), 0);
        sqe.user_data = tag_cancel;
        return true;
    }

    fn complete(s: *State, op: *Op, res_in: i32, out: *backend.Drained) void {
        completeWith(s, op, res_in, out);
    }

    fn completeWith(s: *State, op: *Op, res_in: i64, out: *backend.Drained) void {
        var res: i64 = res_in;
        switch (op.kind) {
            .timeout => if (res == errno(.TIME)) {
                res = 0; // expiry is success
            },
            .fstat, .stat => {
                const sx: *linux.Statx = @ptrCast(@alignCast(op.priv[p_extra].?));
                if (res >= 0) {
                    const o: *op_mod.Stat = @ptrCast(@alignCast(op.buf.?));
                    const fmt = sx.mode & linux.S.IFMT;
                    o.* = .{
                        .size = sx.size,
                        .mode = sx.mode,
                        .kind = switch (fmt) {
                            linux.S.IFREG => 1,
                            linux.S.IFDIR => 2,
                            linux.S.IFLNK => 3,
                            else => 0,
                        },
                    };
                    res = 0;
                }
                s.allocator.destroy(sx);
                op.priv[p_extra] = null;
            },
            .accept => if (res >= 0 and op.buf != null) {
                op.aux = socklenOf(op).*;
            },
            .futex_wait, .futex_wake => if (!s.has_futex) {
                res = errno(.NOSYS);
            },
            .ftruncate => if (!s.has_ftruncate) {
                res = errno(.NOSYS);
            } else if (op.offset < 0) {
                res = errno(.INVAL);
            },
            .sendfile => if (sfOf(op)) |sf| {
                _ = linux.close(sf.rfd);
                _ = linux.close(sf.wfd);
                s.allocator.destroy(sf);
                op.priv[p_extra] = null;
            },
            else => {},
        }
        unlink(s, op);
        op.result = res;
        out.done.push(op);
    }

    /// futex_wait with a timeout owns two CQEs (the wait and its LINK_TIMEOUT); complete on the last.
    fn futexCqe(s: *State, op: *Op, stage: u64, res: i32, out: *backend.Drained) void {
        if (stage == stage_timeout) {
            // -ECANCELED means the wait finished first; anything else (-ETIME, or a positive
            // count on newer kernels) means the timeout fired and cancelled the wait.
            if (res != errno(.CANCELED)) op.priv[p_extra] = @ptrFromInt(1);
        } else {
            op.result = res;
        }
        const left = @intFromPtr(op.priv[p_pend]) - 1;
        op.priv[p_pend] = @ptrFromInt(left);
        if (left != 0) return;
        var r: i64 = op.result;
        if (op.priv[p_extra] != null and r == errno(.CANCELED)) r = errno(.TIMEDOUT);
        op.priv[p_extra] = null;
        completeWith(s, op, r, out);
    }

    fn sfDone(s: *State, op: *Op, sf: *Sendfile, res: i64, out: *backend.Drained) void {
        // Short results are reported as success; an error only when nothing was moved.
        const r: i64 = if (res >= 0 or (sf.total > 0 and res != errno(.CANCELED))) @intCast(sf.total) else res;
        completeWith(s, op, r, out);
    }

    fn sendfileCqe(s: *State, op: *Op, sf: *Sendfile, res: i32, out: *backend.Drained) void {
        if (s.closing) return sfDone(s, op, sf, errno(.CANCELED), out);
        if (res < 0) return sfDone(s, op, sf, res, out);
        // Stop before queueing the next stage.
        if (sf.cancel_requested) return sfDone(s, op, sf, errno(.CANCELED), out);
        if (!sf.draining) {
            if (res == 0) return sfDone(s, op, sf, 0, out); // EOF on the input
            const n: usize = @intCast(res);
            if (sf.in_off >= 0) sf.in_off += res;
            sf.pending = n;
            sf.draining = true;
            sfDrainSqe(s, op, sf) catch return sfDone(s, op, sf, errno(.AGAIN), out);
        } else {
            if (res == 0) return sfDone(s, op, sf, errno(.PIPE), out);
            const n: usize = @intCast(res);
            sf.total += n;
            sf.pending -= n;
            sf.remaining -= n;
            if (sf.pending > 0) {
                sfDrainSqe(s, op, sf) catch return sfDone(s, op, sf, errno(.AGAIN), out);
            } else if (sf.remaining == 0) {
                return sfDone(s, op, sf, 0, out);
            } else {
                sf.draining = false;
                sfFillSqe(s, op, sf) catch return sfDone(s, op, sf, errno(.AGAIN), out);
            }
        }
    }

    fn onCqe(s: *State, ud: u64, res: i32, out: *backend.Drained) void {
        const stage = ud & 1;
        const op: *Op = @ptrFromInt(@as(usize, @intCast(ud & ~@as(u64, 1))));
        switch (op.kind) {
            .futex_wait => if (s.has_futex) return futexCqe(s, op, stage, res, out),
            .sendfile => if (sfOf(op)) |sf| return sendfileCqe(s, op, sf, res, out),
            else => {},
        }
        complete(s, op, res, out);
    }

    /// Reaps every CQE currently available. Returns true if the wake CQE was among them.
    fn reap(s: *State, out: *backend.Drained, rearm: bool) void {
        var cqes: [64]linux.io_uring_cqe = undefined;
        // With COOP_TASKRUN, completions are only posted when we enter the kernel; do so when the
        // kernel says some are waiting (no-op, and no syscall, on a plain ring).
        if (@atomicLoad(u32, s.ring.sq.flags, .unordered) & linux.IORING_SQ_TASKRUN != 0) {
            _ = linux.io_uring_enter(s.ring.fd, 0, 0, linux.IORING_ENTER_GETEVENTS, null);
        }
        var woke = false;
        while (true) {
            const n = s.ring.copy_cqes(&cqes, 0) catch break;
            if (n == 0) break;
            for (cqes[0..n]) |cqe| {
                switch (cqe.user_data) {
                    tag_wake => {
                        s.efd_armed = false;
                        woke = true;
                    },
                    tag_cancel => {},
                    else => onCqe(s, cqe.user_data, cqe.res, out),
                }
            }
        }
        if (woke and rearm) armWake(s) catch {};
    }

    /// Moves the posted stack into `out` in FIFO order. Ownership of the nodes passes to the
    /// loop, which frees them with std.heap.c_allocator.
    fn drainPosts(s: *State, out: *backend.Drained) void {
        var stack = @atomicRmw(?*backend.PostNode, &s.posts, .Xchg, null, .acquire);
        var fifo: ?*backend.PostNode = null;
        while (stack) |n| {
            stack = n.next;
            n.next = fifo;
            fifo = n;
        }
        while (fifo) |n| {
            fifo = n.next;
            out.pushPost(n);
        }
    }

    fn poll(ctx: *anyopaque, block: bool, out: *backend.Drained) void {
        const s = st(ctx);
        // A failed re-arm (full SQ) would silence `wake` and `post` for good: try again.
        if (!s.efd_armed and !s.closing) armWake(s) catch {};
        reap(s, out, true);
        drainPosts(s, out);
        drainRd(s, out);

        if (block and out.done.isEmpty() and out.posts_head == null) {
            _ = s.ring.submit_and_wait(1) catch |e| switch (e) {
                error.SignalInterrupt => {},
                else => {},
            };
            reap(s, out, true);
            drainPosts(s, out);
            drainRd(s, out);
        } else {
            _ = s.ring.submit() catch {};
            reap(s, out, true);
        }
    }

    fn wake(ctx: *anyopaque) void {
        const s = st(ctx);
        const one: u64 = 1;
        while (true) {
            const r = linux.write(s.efd, std.mem.asBytes(&one), 8);
            if (linux.errno(r) == .INTR) continue;
            break; // EAGAIN means the counter is saturated, i.e. already pending
        }
    }

    fn post(ctx: *anyopaque, func: backend.PostFn, ud: ?*anyopaque) anyerror!void {
        const s = st(ctx);
        const node = try std.heap.c_allocator.create(backend.PostNode);
        node.* = .{ .func = func, .ud = ud };
        var head = @atomicLoad(?*backend.PostNode, &s.posts, .monotonic);
        while (true) {
            node.next = head;
            head = @cmpxchgWeak(?*backend.PostNode, &s.posts, head, node, .release, .monotonic) orelse break;
        }
        wake(ctx);
    }

    fn pollable(ctx: *anyopaque) isize {
        return st(ctx).ring.fd;
    }

    fn destroy(ctx: *anyopaque, out: *backend.Drained) void {
        const s = st(ctx);
        const allocator = s.allocator;
        s.closing = true;

        // Stop the readdir helpers first: queued requests complete as canceled, running ones finish.
        if (s.rd_nthreads > 0) {
            @atomicStore(bool, &s.rd_closing, true, .release);
            const n: u64 = s.rd_nthreads;
            _ = linux.write(s.rd_efd, std.mem.asBytes(&n), 8);
            for (s.rd_threads[0..s.rd_nthreads]) |t| t.?.join();
            drainRd(s, out);
        }
        if (s.rd_efd >= 0) _ = linux.close(s.rd_efd);

        // Cancel the wake read and every outstanding op.
        if (s.efd_armed) {
            if (getSqe(s)) |sqe| {
                sqe.prep_cancel(tag_wake, 0);
                sqe.user_data = tag_cancel;
            } else |_| {}
        }
        var cur = s.live_head;
        while (cur) |op| {
            // Read the link first: completing an op unlinks it and clears its `next`.
            cur = @ptrCast(@alignCast(op.priv[p_next]));
            const sqe = getSqe(s) catch {
                // Still full: only submit (never reap, which could unlink ops we have yet to
                // visit) and retry once; an op that cannot be cancelled here is waited for below.
                _ = s.ring.submit() catch {};
                const again = getSqe(s) catch continue;
                again.prep_cancel(@intFromPtr(op), 0);
                again.user_data = tag_cancel;
                continue;
            };
            sqe.prep_cancel(@intFromPtr(op), 0);
            sqe.user_data = tag_cancel;
        }

        // Wait until the kernel has returned everything we own.
        while (s.inflight > 0 or s.efd_armed) {
            _ = s.ring.submit_and_wait(1) catch |e| switch (e) {
                error.SignalInterrupt => continue,
                else => break,
            };
            reap(s, out, false);
        }
        reap(s, out, false);

        // Still-queued posts go to the loop, which runs and frees them.
        drainPosts(s, out);

        _ = linux.close(s.efd);
        s.ring.deinit();
        allocator.destroy(s);
    }
} else struct {};

// ============================================================================================
// Tests (drive the vtable directly)
// ============================================================================================

const testing = std.testing;

const TestEnv = struct {
    b: backend.Backend,
    out: backend.Drained = .{},

    fn init() !TestEnv {
        if (comptime !supported) return error.SkipZigTest;
        const b = create(std.heap.page_allocator, .{ .entries = 32 }) catch return error.SkipZigTest;
        return .{ .b = b };
    }

    fn submit(e: *TestEnv, op: *Op) !void {
        try e.b.vtable.submit(e.b.ctx, op);
    }

    fn poll(e: *TestEnv, block: bool) void {
        e.b.vtable.poll(e.b.ctx, block, &e.out);
    }

    /// Polls (blocking) until `n` ops are done, returns them in completion order.
    fn waitDone(e: *TestEnv, n: usize, list: []*Op) !void {
        var got: usize = 0;
        var spins: usize = 0;
        while (got < n) {
            while (e.out.done.pop()) |op| {
                list[got] = op;
                got += 1;
            }
            if (got >= n) break;
            e.poll(true);
            spins += 1;
            if (spins > 1000) return error.TestTimeout;
        }
    }

    fn runOne(e: *TestEnv, op: *Op) !i64 {
        try e.submit(op);
        var l: [1]*Op = undefined;
        try e.waitDone(1, &l);
        try testing.expect(l[0] == op);
        return op.result;
    }
};

fn testPath(buf: []u8, name: []const u8) [:0]const u8 {
    const n = (std.fmt.bufPrint(buf, "/tmp/origine_uring_{d}_{s}", .{ std.os.linux.getpid(), name }) catch unreachable).len;
    buf[n] = 0;
    return buf[0..n :0];
}

test "uring: write, read, fstat, rename, unlink" {
    if (comptime !supported) return error.SkipZigTest;
    var e = try TestEnv.init();
    var pb: [128]u8 = undefined;
    var pb2: [128]u8 = undefined;
    const path = testPath(&pb, "a");
    const path2 = testPath(&pb2, "b");

    var open_op: Op = .{
        .kind = .open,
        .path = path.ptr,
        .aux = (op_mod.O.RDWR | op_mod.O.CREAT | op_mod.O.TRUNC) | (@as(u64, 0o644) << 32),
    };
    const fd = try e.runOne(&open_op);
    try testing.expect(fd >= 0);

    const msg = "hello io_uring";
    var w: Op = .{ .kind = .write, .fd = @intCast(fd), .offset = 0, .buf = @constCast(msg.ptr), .len = msg.len };
    try testing.expectEqual(@as(i64, msg.len), try e.runOne(&w));

    var rb: [32]u8 = undefined;
    var r: Op = .{ .kind = .read, .fd = @intCast(fd), .offset = 0, .buf = &rb, .len = rb.len };
    try testing.expectEqual(@as(i64, msg.len), try e.runOne(&r));
    try testing.expectEqualStrings(msg, rb[0..msg.len]);

    // offset -1 reads from the current position (still 0 since we used explicit offsets).
    var r2: Op = .{ .kind = .read, .fd = @intCast(fd), .offset = -1, .buf = &rb, .len = rb.len };
    // Explicit offsets don't move the file position, so a position read returns the data.
    try testing.expectEqual(@as(i64, msg.len), try e.runOne(&r2));

    var stat: op_mod.Stat = undefined;
    var fs: Op = .{ .kind = .fstat, .fd = @intCast(fd), .buf = &stat };
    try testing.expectEqual(@as(i64, 0), try e.runOne(&fs));
    try testing.expectEqual(@as(u64, msg.len), stat.size);
    try testing.expectEqual(@as(u32, 1), stat.kind);

    var cl: Op = .{ .kind = .close, .fd = @intCast(fd) };
    try testing.expectEqual(@as(i64, 0), try e.runOne(&cl));

    var rn: Op = .{ .kind = .rename, .path = path.ptr, .path2 = path2.ptr };
    try testing.expectEqual(@as(i64, 0), try e.runOne(&rn));

    var ul: Op = .{ .kind = .unlink, .path = path2.ptr };
    try testing.expectEqual(@as(i64, 0), try e.runOne(&ul));

    var ul2: Op = .{ .kind = .unlink, .path = path2.ptr };
    try testing.expectEqual(-@as(i64, @backingInt(std.os.linux.E.NOENT)), try e.runOne(&ul2));

    var drained: backend.Drained = .{};
    e.b.vtable.destroy(e.b.ctx, &drained);
    try testing.expect(drained.done.isEmpty());
}

test "uring: mkdir and rmdir" {
    if (comptime !supported) return error.SkipZigTest;
    var e = try TestEnv.init();
    var pb: [128]u8 = undefined;
    const path = testPath(&pb, "d");
    var mk: Op = .{ .kind = .mkdir, .path = path.ptr, .aux = 0o755 };
    try testing.expectEqual(@as(i64, 0), try e.runOne(&mk));
    var st_: op_mod.Stat = undefined;
    var fs: Op = .{ .kind = .fstat, .path = path.ptr, .buf = &st_ };
    try testing.expectEqual(@as(i64, 0), try e.runOne(&fs));
    try testing.expectEqual(@as(u32, 2), st_.kind);
    var rm: Op = .{ .kind = .unlink, .path = path.ptr, .flags = 1 };
    try testing.expectEqual(@as(i64, 0), try e.runOne(&rm));
    var d: backend.Drained = .{};
    e.b.vtable.destroy(e.b.ctx, &d);
}

test "uring: nop and timeout" {
    if (comptime !supported) return error.SkipZigTest;
    var e = try TestEnv.init();
    var n: Op = .{ .kind = .nop };
    try testing.expectEqual(@as(i64, 0), try e.runOne(&n));

    var ts0: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts0);
    var t: Op = .{ .kind = .timeout, .aux = 30 * std.time.ns_per_ms };
    try testing.expectEqual(@as(i64, 0), try e.runOne(&t));
    var ts1: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts1);
    const el_ns = (ts1.sec - ts0.sec) * std.time.ns_per_s + (ts1.nsec - ts0.nsec);
    try testing.expect(el_ns >= 25 * std.time.ns_per_ms);

    var d: backend.Drained = .{};
    e.b.vtable.destroy(e.b.ctx, &d);
}

test "uring: cancel a timeout" {
    if (comptime !supported) return error.SkipZigTest;
    var e = try TestEnv.init();
    var t: Op = .{ .kind = .timeout, .aux = 60 * std.time.ns_per_s };
    try e.submit(&t);
    try testing.expect(e.b.vtable.cancel(e.b.ctx, &t));
    var l: [1]*Op = undefined;
    try e.waitDone(1, &l);
    try testing.expectEqual(-@as(i64, @backingInt(std.os.linux.E.CANCELED)), t.result);
    // Already completed: cancel reports false.
    try testing.expect(!e.b.vtable.cancel(e.b.ctx, &t));
    var d: backend.Drained = .{};
    e.b.vtable.destroy(e.b.ctx, &d);
}

const WakeCtx = struct {
    b: backend.Backend,
    hit: u32 = 0,

    fn run(self: *WakeCtx) void {
        var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
        _ = std.os.linux.nanosleep(&ts, null);
        self.b.vtable.post(self.b.ctx, onPost, self) catch unreachable;
    }

    fn onPost(ud: ?*anyopaque) callconv(.c) void {
        const self: *WakeCtx = @ptrCast(@alignCast(ud.?));
        self.hit += 1;
    }
};

test "uring: cross-thread post wakes a blocked poll" {
    if (comptime !supported) return error.SkipZigTest;
    var e = try TestEnv.init();
    var wc: WakeCtx = .{ .b = e.b };
    // Keep a far timeout pending so poll(true) would otherwise block for a minute.
    var t: Op = .{ .kind = .timeout, .aux = 60 * std.time.ns_per_s };
    try e.submit(&t);
    const th = try std.Thread.spawn(.{}, WakeCtx.run, .{&wc});
    e.poll(true);
    th.join();
    // post pushes before waking, so the node must be visible now.
    try testing.expect(e.out.posts_head != null);
    var n: usize = 0;
    while (e.out.posts_head) |node| {
        e.out.posts_head = node.next;
        node.func(node.ud);
        n += 1;
    }
    e.out.posts_tail = null;
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(u32, 1), wc.hit);

    // Plain wake with nothing to deliver also unblocks poll.
    e.b.vtable.wake(e.b.ctx);
    e.poll(true);
    try testing.expect(e.out.done.isEmpty());

    // And after a wake the eventfd must be re-armed: wake again.
    e.b.vtable.wake(e.b.ctx);
    e.poll(true);

    var d: backend.Drained = .{};
    e.b.vtable.destroy(e.b.ctx, &d);
    try testing.expectEqual(-@as(i64, @backingInt(std.os.linux.E.CANCELED)), t.result);
    try testing.expect(d.done.pop().? == &t);
}

test "uring: destroy with ops in flight completes them as canceled" {
    if (comptime !supported) return error.SkipZigTest;
    var e = try TestEnv.init();
    var t1: Op = .{ .kind = .timeout, .aux = 60 * std.time.ns_per_s };
    var t2: Op = .{ .kind = .timeout, .aux = 120 * std.time.ns_per_s };
    var n: Op = .{ .kind = .nop };
    try e.submit(&t1);
    try e.submit(&t2);
    try e.submit(&n); // never flushed before destroy; must still be accounted for
    var d: backend.Drained = .{};
    e.b.vtable.destroy(e.b.ctx, &d);
    var count: usize = 0;
    while (d.done.pop()) |op| {
        count += 1;
        if (op.kind == .timeout) {
            try testing.expectEqual(-@as(i64, @backingInt(std.os.linux.E.CANCELED)), op.result);
        } else {
            try testing.expectEqual(@as(i64, 0), op.result);
        }
    }
    try testing.expectEqual(@as(usize, 3), count);
}

test "uring: pollable fd and non-blocking poll" {
    if (comptime !supported) return error.SkipZigTest;
    var e = try TestEnv.init();
    try testing.expect(e.b.vtable.pollable(e.b.ctx) >= 0);
    e.poll(false);
    try testing.expect(e.out.done.isEmpty());
    var d: backend.Drained = .{};
    e.b.vtable.destroy(e.b.ctx, &d);
}

// ---- tests for the extended op kinds ----------------------------------------------------

fn eno(e: std.os.linux.E) i64 {
    return -@as(i64, @backingInt(e));
}

fn openRw(e: *TestEnv, path: [:0]const u8) !isize {
    var o: Op = .{
        .kind = .open,
        .path = path.ptr,
        .aux = (op_mod.O.RDWR | op_mod.O.CREAT | op_mod.O.TRUNC) | (@as(u64, 0o644) << 32),
    };
    const fd = try e.runOne(&o);
    try testing.expect(fd >= 0);
    return @intCast(fd);
}

fn closeFd(e: *TestEnv, fd: isize) !void {
    var c: Op = .{ .kind = .close, .fd = fd };
    try testing.expectEqual(@as(i64, 0), try e.runOne(&c));
}

fn unlinkP(e: *TestEnv, path: [:0]const u8) !void {
    var u: Op = .{ .kind = .unlink, .path = path.ptr };
    try testing.expectEqual(@as(i64, 0), try e.runOne(&u));
}

fn finishEnv(e: *TestEnv) void {
    var d: backend.Drained = .{};
    e.b.vtable.destroy(e.b.ctx, &d);
}

test "uring: fsync and fdatasync after write" {
    if (comptime !supported) return error.SkipZigTest;
    var e = try TestEnv.init();
    var pb: [128]u8 = undefined;
    const path = testPath(&pb, "fsync");
    const fd = try openRw(&e, path);
    const msg = "sync me";
    var w: Op = .{ .kind = .write, .fd = fd, .offset = 0, .buf = @constCast(msg.ptr), .len = msg.len };
    try testing.expectEqual(@as(i64, msg.len), try e.runOne(&w));
    var f: Op = .{ .kind = .fsync, .fd = fd };
    try testing.expectEqual(@as(i64, 0), try e.runOne(&f));
    var fd2: Op = .{ .kind = .fsync, .fd = fd, .flags = 1 };
    try testing.expectEqual(@as(i64, 0), try e.runOne(&fd2));
    var bad: Op = .{ .kind = .fsync, .fd = 9999 };
    try testing.expectEqual(eno(.BADF), try e.runOne(&bad));
    try closeFd(&e, fd);
    try unlinkP(&e, path);
    finishEnv(&e);
}

test "uring: fallocate then fstat" {
    if (comptime !supported) return error.SkipZigTest;
    var e = try TestEnv.init();
    var pb: [128]u8 = undefined;
    const path = testPath(&pb, "falloc");
    const fd = try openRw(&e, path);
    var fa: Op = .{ .kind = .fallocate, .fd = fd, .offset = 0, .len = 8192 };
    const r = try e.runOne(&fa);
    if (r == eno(.OPNOTSUPP) or r == eno(.INVAL)) {
        try closeFd(&e, fd);
        try unlinkP(&e, path);
        finishEnv(&e);
        return error.SkipZigTest; // filesystem without fallocate
    }
    try testing.expectEqual(@as(i64, 0), r);
    var st_: op_mod.Stat = undefined;
    var fs: Op = .{ .kind = .fstat, .fd = fd, .buf = &st_ };
    try testing.expectEqual(@as(i64, 0), try e.runOne(&fs));
    try testing.expectEqual(@as(u64, 8192), st_.size);

    // KEEP_SIZE past the end leaves the size alone.
    var fk: Op = .{ .kind = .fallocate, .fd = fd, .offset = 8192, .len = 4096, .aux = op_mod.FallocFlags.KEEP_SIZE };
    try testing.expectEqual(@as(i64, 0), try e.runOne(&fk));
    try testing.expectEqual(@as(i64, 0), try e.runOne(&fs));
    try testing.expectEqual(@as(u64, 8192), st_.size);
    try closeFd(&e, fd);
    try unlinkP(&e, path);
    finishEnv(&e);
}

test "uring: writev and readv, positional and current" {
    if (comptime !supported) return error.SkipZigTest;
    var e = try TestEnv.init();
    var pb: [128]u8 = undefined;
    const path = testPath(&pb, "vec");
    const fd = try openRw(&e, path);

    var iw = [_]op_mod.Iovec{
        .{ .base = @constCast("hello "), .len = 6 },
        .{ .base = @constCast("vectored"), .len = 8 },
    };
    var w: Op = .{ .kind = .writev, .fd = fd, .offset = 0, .buf = &iw, .len = iw.len };
    try testing.expectEqual(@as(i64, 14), try e.runOne(&w));

    var a: [5]u8 = undefined;
    var b: [20]u8 = undefined;
    var ir = [_]op_mod.Iovec{ .{ .base = &a, .len = a.len }, .{ .base = &b, .len = b.len } };
    var r: Op = .{ .kind = .readv, .fd = fd, .offset = 0, .buf = &ir, .len = ir.len };
    try testing.expectEqual(@as(i64, 14), try e.runOne(&r));
    try testing.expectEqualStrings("hello", &a);
    try testing.expectEqualStrings(" vectored", b[0..9]);

    // preadv at offset 6.
    var c: [8]u8 = undefined;
    var ic = [_]op_mod.Iovec{.{ .base = &c, .len = c.len }};
    var r2: Op = .{ .kind = .readv, .fd = fd, .offset = 6, .buf = &ic, .len = 1 };
    try testing.expectEqual(@as(i64, 8), try e.runOne(&r2));
    try testing.expectEqualStrings("vectored", &c);

    // offset -1 uses (and advances) the current position, which starts at 0.
    var r3: Op = .{ .kind = .readv, .fd = fd, .offset = -1, .buf = &ic, .len = 1 };
    try testing.expectEqual(@as(i64, 8), try e.runOne(&r3));
    try testing.expectEqualStrings("hello ve", &c);
    try testing.expectEqual(@as(i64, 6), try e.runOne(&r3));
    try testing.expectEqualStrings("ctored", c[0..6]);

    try closeFd(&e, fd);
    try unlinkP(&e, path);
    finishEnv(&e);
}

test "uring: stat path, nofollow on a symlink, link" {
    if (comptime !supported) return error.SkipZigTest;
    var e = try TestEnv.init();
    var pb: [128]u8 = undefined;
    var pl: [128]u8 = undefined;
    var ph: [128]u8 = undefined;
    const path = testPath(&pb, "st");
    const sym = testPath(&pl, "st_sym");
    const hard = testPath(&ph, "st_hard");
    const fd = try openRw(&e, path);
    const msg = "12345";
    var w: Op = .{ .kind = .write, .fd = fd, .offset = 0, .buf = @constCast(msg.ptr), .len = msg.len };
    _ = try e.runOne(&w);
    try closeFd(&e, fd);
    try testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.symlink(path.ptr, sym.ptr)));

    var s: op_mod.Stat = undefined;
    var o: Op = .{ .kind = .stat, .path = sym.ptr, .buf = &s };
    try testing.expectEqual(@as(i64, 0), try e.runOne(&o));
    try testing.expectEqual(@as(u32, 1), s.kind);
    try testing.expectEqual(@as(u64, 5), s.size);

    var o2: Op = .{ .kind = .stat, .path = sym.ptr, .buf = &s, .flags = 1 };
    try testing.expectEqual(@as(i64, 0), try e.runOne(&o2));
    try testing.expectEqual(@as(u32, 3), s.kind);

    var miss: Op = .{ .kind = .stat, .path = hard.ptr, .buf = &s };
    try testing.expectEqual(eno(.NOENT), try e.runOne(&miss));

    var ln: Op = .{ .kind = .link, .path = path.ptr, .path2 = hard.ptr };
    try testing.expectEqual(@as(i64, 0), try e.runOne(&ln));
    try testing.expectEqual(@as(i64, 0), try e.runOne(&miss));
    try testing.expectEqual(@as(u32, 1), s.kind);
    try testing.expectEqual(@as(u64, 5), s.size);

    try unlinkP(&e, hard);
    try unlinkP(&e, sym);
    try unlinkP(&e, path);
    finishEnv(&e);
}

test "uring: rename between directories with fd2" {
    if (comptime !supported) return error.SkipZigTest;
    var e = try TestEnv.init();
    var pa: [128]u8 = undefined;
    var pbb: [128]u8 = undefined;
    var pf: [160]u8 = undefined;
    const da = testPath(&pa, "dirA");
    const db = testPath(&pbb, "dirB");
    var mka: Op = .{ .kind = .mkdir, .path = da.ptr, .aux = 0o755 };
    var mkb: Op = .{ .kind = .mkdir, .path = db.ptr, .aux = 0o755 };
    try testing.expectEqual(@as(i64, 0), try e.runOne(&mka));
    try testing.expectEqual(@as(i64, 0), try e.runOne(&mkb));
    const fn_ = try std.fmt.bufPrint(&pf, "{s}/f", .{da});
    pf[fn_.len] = 0;
    const fpath: [:0]const u8 = pf[0..fn_.len :0];
    const f = try openRw(&e, fpath);
    try closeFd(&e, f);

    var oa: Op = .{ .kind = .open, .path = da.ptr, .aux = op_mod.O.RDONLY | op_mod.O.DIRECTORY };
    var ob: Op = .{ .kind = .open, .path = db.ptr, .aux = op_mod.O.RDONLY | op_mod.O.DIRECTORY };
    const fa: isize = @intCast(try e.runOne(&oa));
    const fb: isize = @intCast(try e.runOne(&ob));
    try testing.expect(fa >= 0 and fb >= 0);

    var rn: Op = .{ .kind = .rename, .fd = fa, .fd2 = fb, .path = "f", .path2 = "g" };
    try testing.expectEqual(@as(i64, 0), try e.runOne(&rn));
    var s: op_mod.Stat = undefined;
    var sg: Op = .{ .kind = .stat, .fd = fb, .path = "g", .buf = &s };
    try testing.expectEqual(@as(i64, 0), try e.runOne(&sg));
    var sf: Op = .{ .kind = .stat, .fd = fa, .path = "f", .buf = &s };
    try testing.expectEqual(eno(.NOENT), try e.runOne(&sf));

    var ug: Op = .{ .kind = .unlink, .fd = fb, .path = "g" };
    try testing.expectEqual(@as(i64, 0), try e.runOne(&ug));
    try closeFd(&e, fa);
    try closeFd(&e, fb);
    var ra: Op = .{ .kind = .unlink, .path = da.ptr, .flags = 1 };
    var rb: Op = .{ .kind = .unlink, .path = db.ptr, .flags = 1 };
    try testing.expectEqual(@as(i64, 0), try e.runOne(&ra));
    try testing.expectEqual(@as(i64, 0), try e.runOne(&rb));
    finishEnv(&e);
}

const Tcp = struct {
    listener: i32,
    client: i32,
    addr: std.os.linux.sockaddr.in,
};

fn tcpListen() !Tcp {
    const linux = std.os.linux;
    const l: i32 = @intCast(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0));
    if (l < 0) return error.SkipZigTest;
    var addr: linux.sockaddr.in = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    if (linux.errno(linux.bind(l, @ptrCast(&addr), @sizeOf(@TypeOf(addr)))) != .SUCCESS) return error.SkipZigTest;
    if (linux.errno(linux.listen(l, 4)) != .SUCCESS) return error.SkipZigTest;
    var len: linux.socklen_t = @sizeOf(@TypeOf(addr));
    if (linux.errno(linux.getsockname(l, @ptrCast(&addr), &len)) != .SUCCESS) return error.SkipZigTest;
    const c: i32 = @intCast(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0));
    return .{ .listener = l, .client = c, .addr = addr };
}

/// Connected loopback pair through connect + accept ops. Returns {server side, client side}.
fn tcpPair(e: *TestEnv, peer: ?*std.os.linux.sockaddr.in, peer_len: ?*u64) ![2]i32 {
    const t = try tcpListen();
    var addr = t.addr;
    var acc_addr: std.os.linux.sockaddr.in = undefined;
    var acc: Op = .{
        .kind = .accept,
        .fd = t.listener,
        .buf = if (peer != null) &acc_addr else null,
        .len = @sizeOf(std.os.linux.sockaddr.in),
    };
    var con: Op = .{ .kind = .connect, .fd = t.client, .buf = &addr, .len = @sizeOf(@TypeOf(addr)) };
    try e.submit(&acc);
    try e.submit(&con);
    var l: [2]*Op = undefined;
    try e.waitDone(2, &l);
    try testing.expectEqual(@as(i64, 0), con.result);
    try testing.expect(acc.result >= 0);
    if (peer) |p| {
        p.* = acc_addr;
        peer_len.?.* = acc.aux;
    }
    _ = std.os.linux.close(t.listener);
    return .{ @intCast(acc.result), t.client };
}

test "uring: connect, accept, send, recv" {
    if (comptime !supported) return error.SkipZigTest;
    var e = try TestEnv.init();
    var peer: std.os.linux.sockaddr.in = undefined;
    var plen: u64 = 0;
    const pair = try tcpPair(&e, &peer, &plen);
    try testing.expectEqual(@as(u64, @sizeOf(std.os.linux.sockaddr.in)), plen);
    try testing.expectEqual(@as(u16, std.os.linux.AF.INET), @as(u16, @intCast(peer.family)));

    // accept without an address buffer too.
    const msg = "ping over tcp";
    var sd: Op = .{ .kind = .send, .fd = pair[1], .buf = @constCast(msg.ptr), .len = msg.len };
    try testing.expectEqual(@as(i64, msg.len), try e.runOne(&sd));
    var rb: [32]u8 = undefined;
    var rc: Op = .{ .kind = .recv, .fd = pair[0], .buf = &rb, .len = rb.len };
    try testing.expectEqual(@as(i64, msg.len), try e.runOne(&rc));
    try testing.expectEqualStrings(msg, rb[0..msg.len]);

    // recv pending, completed by a later send.
    var rc2: Op = .{ .kind = .recv, .fd = pair[0], .buf = &rb, .len = rb.len };
    try e.submit(&rc2);
    e.poll(false);
    try testing.expect(e.out.done.isEmpty());
    var sd2: Op = .{ .kind = .send, .fd = pair[1], .buf = @constCast("x"), .len = 1 };
    try e.submit(&sd2);
    var l: [2]*Op = undefined;
    try e.waitDone(2, &l);
    try testing.expectEqual(@as(i64, 1), rc2.result);

    // Peer closes: recv returns 0.
    _ = std.os.linux.close(pair[1]);
    var rc3: Op = .{ .kind = .recv, .fd = pair[0], .buf = &rb, .len = rb.len };
    try testing.expectEqual(@as(i64, 0), try e.runOne(&rc3));
    _ = std.os.linux.close(pair[0]);
    finishEnv(&e);
}

test "uring: sendmsg and recvmsg" {
    if (comptime !supported) return error.SkipZigTest;
    const linux = std.os.linux;
    var e = try TestEnv.init();
    var fds: [2]i32 = undefined;
    if (linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &fds)) != .SUCCESS)
        return error.SkipZigTest;

    var out_buf = "msg-over-iov".*;
    var siov = [_]std.posix.iovec_const{.{ .base = &out_buf, .len = out_buf.len }};
    var smh: linux.msghdr_const = .{ .name = null, .namelen = 0, .iov = &siov, .iovlen = 1, .control = null, .controllen = 0, .flags = 0 };
    var sm: Op = .{ .kind = .sendmsg, .fd = fds[0], .buf = &smh };
    try testing.expectEqual(@as(i64, out_buf.len), try e.runOne(&sm));

    var in_buf: [32]u8 = undefined;
    var riov = [_]std.posix.iovec{.{ .base = &in_buf, .len = in_buf.len }};
    var rmh: linux.msghdr = .{ .name = null, .namelen = 0, .iov = &riov, .iovlen = 1, .control = null, .controllen = 0, .flags = 0 };
    var rm: Op = .{ .kind = .recvmsg, .fd = fds[1], .buf = &rmh };
    try testing.expectEqual(@as(i64, out_buf.len), try e.runOne(&rm));
    try testing.expectEqualStrings("msg-over-iov", in_buf[0..out_buf.len]);
    _ = linux.close(fds[0]);
    _ = linux.close(fds[1]);
    finishEnv(&e);
}

fn needFutex(e: *TestEnv) !void {
    if (e.b.vtable.caps & backend.Caps.futex == 0) {
        finishEnv(e);
        return error.SkipZigTest;
    }
}

test "uring: futex wait woken by futex wake" {
    if (comptime !supported) return error.SkipZigTest;
    var e = try TestEnv.init();
    try needFutex(&e);
    var word: u32 align(4) = 0;
    var wait: Op = .{ .kind = .futex_wait, .buf = &word, .aux = 0 };
    try e.submit(&wait);
    e.poll(false);
    try testing.expect(e.out.done.isEmpty());
    var wk: Op = .{ .kind = .futex_wake, .buf = &word, .aux = 1 };
    try e.submit(&wk);
    var l: [2]*Op = undefined;
    try e.waitDone(2, &l);
    try testing.expectEqual(@as(i64, 0), wait.result);
    try testing.expectEqual(@as(i64, 1), wk.result);

    // Same with a (long) timeout armed: woken before it fires.
    var wait2: Op = .{ .kind = .futex_wait, .buf = &word, .aux = 0, .offset = 30 * std.time.ns_per_s };
    try e.submit(&wait2);
    e.poll(false);
    try e.submit(&wk);
    try e.waitDone(2, &l);
    try testing.expectEqual(@as(i64, 0), wait2.result);
    try testing.expectEqual(@as(i64, 1), wk.result);

    // Nothing waiting: wake reports 0.
    try testing.expectEqual(@as(i64, 0), try e.runOne(&wk));
    finishEnv(&e);
}

test "uring: futex EAGAIN on mismatch and ETIMEDOUT" {
    if (comptime !supported) return error.SkipZigTest;
    var e = try TestEnv.init();
    try needFutex(&e);
    var word: u32 align(4) = 5;
    var bad: Op = .{ .kind = .futex_wait, .buf = &word, .aux = 7 };
    try testing.expectEqual(eno(.AGAIN), try e.runOne(&bad));
    var bad_t: Op = .{ .kind = .futex_wait, .buf = &word, .aux = 7, .offset = std.time.ns_per_s };
    try testing.expectEqual(eno(.AGAIN), try e.runOne(&bad_t));

    var ts0: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts0);
    var to: Op = .{ .kind = .futex_wait, .buf = &word, .aux = 5, .offset = 30 * std.time.ns_per_ms };
    try testing.expectEqual(eno(.TIMEDOUT), try e.runOne(&to));
    var ts1: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts1);
    const el_ns = (ts1.sec - ts0.sec) * std.time.ns_per_s + (ts1.nsec - ts0.nsec);
    try testing.expect(el_ns >= 25 * std.time.ns_per_ms);

    // Explicit cancel of an untimed wait reports ECANCELED.
    var w: Op = .{ .kind = .futex_wait, .buf = &word, .aux = 5 };
    try e.submit(&w);
    e.poll(false);
    try testing.expect(e.b.vtable.cancel(e.b.ctx, &w));
    var l: [1]*Op = undefined;
    try e.waitDone(1, &l);
    try testing.expectEqual(eno(.CANCELED), w.result);
    finishEnv(&e);
}

fn writeAll(e: *TestEnv, fd: isize, data: []const u8) !void {
    var w: Op = .{ .kind = .write, .fd = fd, .offset = 0, .buf = @constCast(data.ptr), .len = data.len };
    try testing.expectEqual(@as(i64, @intCast(data.len)), try e.runOne(&w));
}

test "uring: sendfile file to file" {
    if (comptime !supported) return error.SkipZigTest;
    var e = try TestEnv.init();
    var p1: [128]u8 = undefined;
    var p2: [128]u8 = undefined;
    const src = testPath(&p1, "sf_src");
    const dst = testPath(&p2, "sf_dst");
    const fin = try openRw(&e, src);
    const fout = try openRw(&e, dst);

    // Bigger than the default 64 KiB pipe so the loop must iterate.
    const n = 300 * 1024 + 17;
    const data = try testing.allocator.alloc(u8, n);
    defer testing.allocator.free(data);
    for (data, 0..) |*b, i| b.* = @truncate(i *% 31);
    try writeAll(&e, fin, data);

    var sf: Op = .{ .kind = .sendfile, .fd = fout, .fd2 = fin, .offset = 0, .len = n };
    try testing.expectEqual(@as(i64, n), try e.runOne(&sf));
    const got = try testing.allocator.alloc(u8, n);
    defer testing.allocator.free(got);
    var r: Op = .{ .kind = .read, .fd = fout, .offset = 0, .buf = got.ptr, .len = n };
    try testing.expectEqual(@as(i64, n), try e.runOne(&r));
    try testing.expectEqualSlices(u8, data, got);

    // Offset in the input; count past EOF yields a short result; then EOF gives 0.
    var sf2: Op = .{ .kind = .sendfile, .fd = fout, .fd2 = fin, .offset = n - 100, .len = 1000 };
    try testing.expectEqual(@as(i64, 100), try e.runOne(&sf2));
    var sf3: Op = .{ .kind = .sendfile, .fd = fout, .fd2 = fin, .offset = n, .len = 1000 };
    try testing.expectEqual(@as(i64, 0), try e.runOne(&sf3));
    var sf4: Op = .{ .kind = .sendfile, .fd = fout, .fd2 = fin, .offset = 0, .len = 0 };
    try testing.expectEqual(@as(i64, 0), try e.runOne(&sf4));
    var bad: Op = .{ .kind = .sendfile, .fd = fout, .fd2 = 9999, .offset = 0, .len = 10 };
    try testing.expectEqual(eno(.BADF), try e.runOne(&bad));

    try closeFd(&e, fin);
    try closeFd(&e, fout);
    try unlinkP(&e, src);
    try unlinkP(&e, dst);
    finishEnv(&e);
}

test "uring: sendfile file to socket" {
    if (comptime !supported) return error.SkipZigTest;
    const linux = std.os.linux;
    var e = try TestEnv.init();
    var p1: [128]u8 = undefined;
    const src = testPath(&p1, "sf_sock");
    const fin = try openRw(&e, src);
    const data = "sendfile to a socket";
    try writeAll(&e, fin, data);

    var fds: [2]i32 = undefined;
    if (linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &fds)) != .SUCCESS)
        return error.SkipZigTest;
    var sf: Op = .{ .kind = .sendfile, .fd = fds[0], .fd2 = fin, .offset = 5, .len = data.len - 5 };
    try testing.expectEqual(@as(i64, data.len - 5), try e.runOne(&sf));
    var rb: [64]u8 = undefined;
    var rc: Op = .{ .kind = .recv, .fd = fds[1], .buf = &rb, .len = rb.len };
    try testing.expectEqual(@as(i64, data.len - 5), try e.runOne(&rc));
    try testing.expectEqualStrings(data[5..], rb[0 .. data.len - 5]);
    _ = linux.close(fds[0]);
    _ = linux.close(fds[1]);
    try closeFd(&e, fin);
    try unlinkP(&e, src);
    finishEnv(&e);
}

test "uring: ftruncate shrink and grow" {
    if (comptime !supported) return error.SkipZigTest;
    var e = try TestEnv.init();
    if (e.b.vtable.caps & backend.Caps.ftruncate == 0) {
        var pb0: [128]u8 = undefined;
        const p0 = testPath(&pb0, "trunc0");
        const fd0 = try openRw(&e, p0);
        var t0: Op = .{ .kind = .ftruncate, .fd = fd0, .offset = 1 };
        try testing.expectEqual(eno(.NOSYS), try e.runOne(&t0));
        try closeFd(&e, fd0);
        try unlinkP(&e, p0);
        finishEnv(&e);
        return error.SkipZigTest;
    }
    var pb: [128]u8 = undefined;
    const path = testPath(&pb, "trunc");
    const fd = try openRw(&e, path);
    try writeAll(&e, fd, "0123456789");
    var st_: op_mod.Stat = undefined;
    var fs: Op = .{ .kind = .fstat, .fd = fd, .buf = &st_ };
    var t: Op = .{ .kind = .ftruncate, .fd = fd, .offset = 4 };
    try testing.expectEqual(@as(i64, 0), try e.runOne(&t));
    try testing.expectEqual(@as(i64, 0), try e.runOne(&fs));
    try testing.expectEqual(@as(u64, 4), st_.size);
    var t2: Op = .{ .kind = .ftruncate, .fd = fd, .offset = 8192 };
    try testing.expectEqual(@as(i64, 0), try e.runOne(&t2));
    try testing.expectEqual(@as(i64, 0), try e.runOne(&fs));
    try testing.expectEqual(@as(u64, 8192), st_.size);
    var bad: Op = .{ .kind = .ftruncate, .fd = 9999, .offset = 0 };
    try testing.expectEqual(eno(.BADF), try e.runOne(&bad));
    try closeFd(&e, fd);
    try unlinkP(&e, path);
    finishEnv(&e);
}

const Listing = struct {
    names: std.ArrayList([]u8) = .empty,
    kinds: std.ArrayList(u8) = .empty,

    fn deinit(l: *Listing) void {
        for (l.names.items) |n| testing.allocator.free(n);
        l.names.deinit(testing.allocator);
        l.kinds.deinit(testing.allocator);
    }

    fn parse(l: *Listing, buf: []const u8) !void {
        var i: usize = 0;
        while (i < buf.len) {
            const kind = buf[i];
            const nl = @as(usize, buf[i + 1]) | (@as(usize, buf[i + 2]) << 8);
            try l.names.append(testing.allocator, try testing.allocator.dupe(u8, buf[i + 3 ..][0..nl]));
            try l.kinds.append(testing.allocator, kind);
            i += 3 + nl;
        }
        try testing.expectEqual(buf.len, i);
    }

    fn find(l: *Listing, name: []const u8) ?u8 {
        var found: ?u8 = null;
        for (l.names.items, l.kinds.items) |n, k| {
            if (std.mem.eql(u8, n, name)) {
                if (found != null) return 255; // duplicate
                found = k;
            }
        }
        return found;
    }
};

/// Reads a whole directory through readdir ops with a `bufsz` buffer.
fn listDir(e: *TestEnv, dfd: isize, bufsz: usize, l: *Listing) !void {
    const buf = try testing.allocator.alloc(u8, bufsz);
    defer testing.allocator.free(buf);
    var cookie: u64 = 0;
    var rounds: usize = 0;
    while (true) {
        var rd: Op = .{ .kind = .readdir, .fd = dfd, .buf = buf.ptr, .len = buf.len, .offset = @intCast(cookie) };
        const n = try e.runOne(&rd);
        try testing.expect(n >= 0);
        if (n == 0) break;
        try l.parse(buf[0..@intCast(n)]);
        cookie = rd.aux;
        rounds += 1;
        try testing.expect(rounds < 100000);
    }
}

fn mkPath(buf: []u8, base: [:0]const u8, name: []const u8) [:0]const u8 {
    const n = (std.fmt.bufPrint(buf, "{s}/{s}", .{ base, name }) catch unreachable).len;
    buf[n] = 0;
    return buf[0..n :0];
}

fn openDir(e: *TestEnv, path: [:0]const u8) !isize {
    var o: Op = .{ .kind = .open, .path = path.ptr, .aux = op_mod.O.RDONLY | op_mod.O.DIRECTORY };
    const fd = try e.runOne(&o);
    try testing.expect(fd >= 0);
    return @intCast(fd);
}

test "uring: readdir kinds, cookie continuation, ERANGE" {
    if (comptime !supported) return error.SkipZigTest;
    var e = try TestEnv.init();
    var pd: [128]u8 = undefined;
    const dir = testPath(&pd, "rd");
    var mk: Op = .{ .kind = .mkdir, .path = dir.ptr, .aux = 0o755 };
    try testing.expectEqual(@as(i64, 0), try e.runOne(&mk));

    var pp: [192]u8 = undefined;
    for ([_][]const u8{ "file_a", "file_b", "file_c" }) |nm| {
        const fd = try openRw(&e, mkPath(&pp, dir, nm));
        try closeFd(&e, fd);
    }
    for ([_][]const u8{ "sub_a", "sub_b" }) |nm| {
        var m: Op = .{ .kind = .mkdir, .path = mkPath(&pp, dir, nm).ptr, .aux = 0o755 };
        try testing.expectEqual(@as(i64, 0), try e.runOne(&m));
    }
    try testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.symlink("file_a", mkPath(&pp, dir, "link_a").ptr)));

    const dfd = try openDir(&e, dir);

    const sizes = [_]usize{ 4096, 64 };
    for (sizes) |sz| {
        var l: Listing = .{};
        defer l.deinit();
        try listDir(&e, dfd, sz, &l);
        try testing.expectEqual(@as(usize, 6), l.names.items.len);
        try testing.expectEqual(@as(?u8, 1), l.find("file_a"));
        try testing.expectEqual(@as(?u8, 1), l.find("file_b"));
        try testing.expectEqual(@as(?u8, 1), l.find("file_c"));
        try testing.expectEqual(@as(?u8, 2), l.find("sub_a"));
        try testing.expectEqual(@as(?u8, 2), l.find("sub_b"));
        try testing.expectEqual(@as(?u8, 3), l.find("link_a"));
        try testing.expectEqual(@as(?u8, null), l.find("."));
        try testing.expectEqual(@as(?u8, null), l.find(".."));
    }

    var tiny: [2]u8 = undefined;
    var rd: Op = .{ .kind = .readdir, .fd = dfd, .buf = &tiny, .len = tiny.len, .offset = 0 };
    try testing.expectEqual(eno(.RANGE), try e.runOne(&rd));

    // Bad fd.
    var bad: Op = .{ .kind = .readdir, .fd = 9999, .buf = &tiny, .len = tiny.len, .offset = 0 };
    try testing.expectEqual(eno(.BADF), try e.runOne(&bad));

    try closeFd(&e, dfd);
    for ([_][]const u8{ "file_a", "file_b", "file_c", "link_a" }) |nm| try unlinkP(&e, mkPath(&pp, dir, nm));
    for ([_][]const u8{ "sub_a", "sub_b" }) |nm| {
        var u: Op = .{ .kind = .unlink, .path = mkPath(&pp, dir, nm).ptr, .flags = 1 };
        try testing.expectEqual(@as(i64, 0), try e.runOne(&u));
    }
    var rm: Op = .{ .kind = .unlink, .path = dir.ptr, .flags = 1 };
    try testing.expectEqual(@as(i64, 0), try e.runOne(&rm));
    finishEnv(&e);
}

test "uring: readdir 2000 entries with a 4096-byte buffer, concurrent dirs, cancel, destroy" {
    if (comptime !supported) return error.SkipZigTest;
    var e = try TestEnv.init();
    var pd: [128]u8 = undefined;
    const dir = testPath(&pd, "rd2000");
    var mk: Op = .{ .kind = .mkdir, .path = dir.ptr, .aux = 0o755 };
    try testing.expectEqual(@as(i64, 0), try e.runOne(&mk));
    var pp: [256]u8 = undefined;
    var nb: [32]u8 = undefined;
    const count = 2000;
    for (0..count) |i| {
        const nm = std.fmt.bufPrint(&nb, "entry_with_longish_name_{d}", .{i}) catch unreachable;
        const fd = try openRw(&e, mkPath(&pp, dir, nm));
        try closeFd(&e, fd);
    }
    const dfd = try openDir(&e, dir);
    var l: Listing = .{};
    defer l.deinit();
    try listDir(&e, dfd, 4096, &l);
    try testing.expectEqual(@as(usize, count), l.names.items.len);
    for (0..count) |i| {
        const nm = std.fmt.bufPrint(&nb, "entry_with_longish_name_{d}", .{i}) catch unreachable;
        try testing.expectEqual(@as(?u8, 1), l.find(nm));
    }

    // Several readdirs at once on separate directory fds (grows the pool), plus a cancel.
    var fds: [6]isize = undefined;
    var bufs: [6][4096]u8 = undefined;
    var ops: [6]Op = undefined;
    for (&fds) |*f| f.* = try openDir(&e, dir);
    for (&fds, &ops, &bufs) |*f, *o, *b| {
        o.* = .{ .kind = .readdir, .fd = f.*, .buf = b, .len = b.len, .offset = 0 };
        try e.submit(o);
    }
    try testing.expect(e.b.vtable.cancel(e.b.ctx, &ops[5]));
    var done: [6]*Op = undefined;
    try e.waitDone(6, &done);
    for (ops[0..5]) |o| try testing.expect(o.result > 0);
    try testing.expect(ops[5].result > 0 or ops[5].result == eno(.CANCELED));
    for (fds) |f| try closeFd(&e, f);

    // Destroy with a readdir outstanding must report it exactly once.
    var pend: Op = .{ .kind = .readdir, .fd = dfd, .buf = &bufs[0], .len = 4096, .offset = 0 };
    try e.submit(&pend);
    var d: backend.Drained = .{};
    e.b.vtable.destroy(e.b.ctx, &d);
    try testing.expect(d.done.pop().? == &pend);
    try testing.expect(d.done.isEmpty());
    try testing.expect(pend.result > 0 or pend.result == eno(.CANCELED));

    // Cleanup via a fresh backend.
    var e2 = try TestEnv.init();
    for (0..count) |i| {
        const nm = std.fmt.bufPrint(&nb, "entry_with_longish_name_{d}", .{i}) catch unreachable;
        try unlinkP(&e2, mkPath(&pp, dir, nm));
    }
    var ud2: Op = .{ .kind = .unlink, .path = dir.ptr, .flags = 1 };
    try testing.expectEqual(@as(i64, 0), try e2.runOne(&ud2));
    var cl: Op = .{ .kind = .close, .fd = dfd };
    try testing.expectEqual(@as(i64, 0), try e2.runOne(&cl));
    finishEnv(&e2);
}
