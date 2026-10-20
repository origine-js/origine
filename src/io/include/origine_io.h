/* origine_io: completion-based async I/O. Ops are caller-owned and must stay alive and unmoved
 * until their callback runs. A loop is driven by one thread (the one calling oio_loop_run);
 * submit/cancel/destroy are loop-thread only; oio_loop_wake and oio_loop_post are thread-safe.
 * Functions return 0 or a value >= 0 on success and -errno on failure. Callbacks receive
 * result >= 0 or -errno (-ECANCELED if cancelled). Paths are UTF-8. */
/* CONTRACT (docs/contracts.md, surface A): this header is the source of truth. Mirrored by
 * src/io/c_api.zig (comptime-checked against this header by `zig build test-io`), the generated
 * rust/crates/origine_io/src/sys_gen.rs (`just gen-contracts`; `just check-contracts` fails when
 * stale) and the Miri fake rust/crates/origine_io/src/mock.rs (signatures checked at compile time).
 * Generator rules: a #define whose value is written with a `ull` suffix becomes a u64 constant in
 * Rust; name every function parameter (names show up in the generated bindings); #define
 * OIO_FDCWD is typed oio_fd by the generator. */
#ifndef ORIGINE_IO_H
#define ORIGINE_IO_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef intptr_t oio_fd;
#define OIO_FDCWD (-1)

typedef struct oio_loop oio_loop;
typedef struct oio_op oio_op;
typedef void (*oio_cb)(oio_op *op, int64_t result);

enum oio_kind {
  OIO_NOP = 0, OIO_OPEN = 1, OIO_CLOSE = 2, OIO_READ = 3, OIO_WRITE = 4,
  OIO_FSTAT = 5, OIO_MKDIR = 6, OIO_UNLINK = 7, OIO_RENAME = 8, OIO_TIMEOUT = 9,
  OIO_FSYNC = 10, OIO_SENDFILE = 11, OIO_FALLOCATE = 12, OIO_SEND = 13, OIO_RECV = 14,
  OIO_SENDMSG = 15, OIO_RECVMSG = 16, OIO_FUTEX_WAIT = 17, OIO_FUTEX_WAKE = 18, OIO_STAT = 19,
  OIO_CONNECT = 20, OIO_ACCEPT = 21, OIO_LINK = 22, OIO_READV = 23, OIO_WRITEV = 24,
  OIO_READDIR = 25, OIO_FTRUNCATE = 26
};

/* oio_fallocate flags */
#define OIO_FALLOC_KEEP_SIZE 1ull

/* Same layout as the platform struct iovec. */
typedef struct oio_iovec { void *base; size_t len; } oio_iovec;

/* Fired timeouts complete with result 0. Destroying a loop cancels its ops (callbacks get
 * -ECANCELED) and runs pending posted functions. oio_loop_run(ONCE) with nothing active blocks
 * until oio_loop_wake/post. Op.aux: open = flags | mode << 32; mkdir = mode; timeout = ns. */
/* open flags (low two bits are the access mode) */
#define OIO_O_RDONLY 0ull
#define OIO_O_WRONLY 1ull
#define OIO_O_RDWR 2ull
#define OIO_O_CREAT 0x100ull
#define OIO_O_TRUNC 0x200ull
#define OIO_O_APPEND 0x400ull
#define OIO_O_EXCL 0x800ull
#define OIO_O_DIRECTORY 0x1000ull

typedef struct oio_stat {
  uint64_t size;
  uint32_t mode;
  uint32_t kind; /* 1 file, 2 directory, 3 symlink, 0 other */
} oio_stat;

struct oio_op {
  /* Set `user` before submitting; everything else is filled by the oio_* calls. */
  oio_cb cb;
  void *user;
  int32_t kind;
  uint32_t flags;
  oio_fd fd;
  oio_fd fd2; /* sendfile input; new dir for rename/link */
  int64_t offset; /* -1 = current position */
  void *buf;
  size_t len;
  const char *path;
  const char *path2;
  uint64_t aux;
  int64_t result;
  void *priv[8]; /* backend scratch, do not touch */
};

enum oio_backend { OIO_BACKEND_AUTO = 0, OIO_BACKEND_URING = 1, OIO_BACKEND_KQUEUE_GCD = 2,
                   OIO_BACKEND_IOCP = 3, OIO_BACKEND_THREADED = 4 };

typedef struct oio_options {
  uint32_t backend; /* enum oio_backend */
  uint32_t entries; /* queue depth / worker count hint, 0 = default */
} oio_options;

enum oio_run_mode { OIO_RUN_ONCE = 0, OIO_RUN_NOWAIT = 1, OIO_RUN_UNTIL_IDLE = 2 };

#define OIO_CAP_NOP (1ull << 0)
#define OIO_CAP_FILE_IO (1ull << 1)
#define OIO_CAP_TIMEOUT (1ull << 2)
#define OIO_CAP_CANCEL (1ull << 3)
#define OIO_CAP_POLLABLE (1ull << 4)
#define OIO_CAP_VECTORED (1ull << 5)
#define OIO_CAP_SOCKETS (1ull << 6)
#define OIO_CAP_FUTEX (1ull << 7)
#define OIO_CAP_SENDFILE (1ull << 8)
#define OIO_CAP_FALLOCATE (1ull << 9)
#define OIO_CAP_LINK (1ull << 10)
#define OIO_CAP_SYNC (1ull << 11)
#define OIO_CAP_READDIR (1ull << 12)
#define OIO_CAP_FTRUNCATE (1ull << 13)

int oio_loop_create(const oio_options *options /* may be NULL */, oio_loop **out);
/* Cancels outstanding ops, runs their callbacks, frees the loop. */
void oio_loop_destroy(oio_loop *loop);
/* Returns the number of active ops (>= 0). ONCE blocks for at least one event. */
int oio_loop_run(oio_loop *loop, int mode);
void oio_loop_wake(oio_loop *loop);
int oio_loop_post(oio_loop *loop, void (*fn)(void *), void *ud);
/* OS handle to poll from a foreign event loop, then call oio_loop_run(NOWAIT); -1 if none. */
intptr_t oio_loop_pollable(oio_loop *loop);
uint32_t oio_loop_active(oio_loop *loop);
uint64_t oio_loop_caps(oio_loop *loop);

int oio_nop(oio_loop *loop, oio_op *op, oio_cb cb);
int oio_open(oio_loop *loop, oio_op *op, oio_fd dirfd, const char *path, uint64_t flags, uint32_t mode, oio_cb cb);
int oio_close(oio_loop *loop, oio_op *op, oio_fd fd, oio_cb cb);
int oio_read(oio_loop *loop, oio_op *op, oio_fd fd, void *buf, size_t len, int64_t offset, oio_cb cb);
int oio_write(oio_loop *loop, oio_op *op, oio_fd fd, const void *buf, size_t len, int64_t offset, oio_cb cb);
int oio_fstat(oio_loop *loop, oio_op *op, oio_fd fd, oio_stat *out, oio_cb cb);
int oio_mkdir(oio_loop *loop, oio_op *op, oio_fd dirfd, const char *path, uint32_t mode, oio_cb cb);
int oio_unlink(oio_loop *loop, oio_op *op, oio_fd dirfd, const char *path, uint32_t rmdir, oio_cb cb);
int oio_rename(oio_loop *loop, oio_op *op, oio_fd old_dirfd, const char *from, oio_fd new_dirfd, const char *to, oio_cb cb);
int oio_link(oio_loop *loop, oio_op *op, oio_fd old_dirfd, const char *old, oio_fd new_dirfd, const char *new_path, oio_cb cb);
/* Path stat (fstatat); nofollow != 0 does not follow a final symlink. */
int oio_stat_at(oio_loop *loop, oio_op *op, oio_fd dirfd, const char *path, uint32_t nofollow, oio_stat *out, oio_cb cb);
int oio_fsync(oio_loop *loop, oio_op *op, oio_fd fd, uint32_t datasync, oio_cb cb);
/* Copies up to count bytes from in_fd (at in_offset, -1 = current) to out_fd; result = bytes. */
int oio_sendfile(oio_loop *loop, oio_op *op, oio_fd out_fd, oio_fd in_fd, int64_t in_offset, size_t count, oio_cb cb);
int oio_fallocate(oio_loop *loop, oio_op *op, oio_fd fd, int64_t offset, size_t len, uint64_t flags, oio_cb cb);
/* msg_flags are the platform's native MSG_* values; msghdr/sockaddr are the platform's native types
 * and must stay valid until the callback. */
int oio_send(oio_loop *loop, oio_op *op, oio_fd fd, const void *buf, size_t len, uint32_t msg_flags, oio_cb cb);
int oio_recv(oio_loop *loop, oio_op *op, oio_fd fd, void *buf, size_t len, uint32_t msg_flags, oio_cb cb);
int oio_sendmsg(oio_loop *loop, oio_op *op, oio_fd fd, void *msghdr, uint32_t msg_flags, oio_cb cb);
int oio_recvmsg(oio_loop *loop, oio_op *op, oio_fd fd, void *msghdr, uint32_t msg_flags, oio_cb cb);
/* Futex on a 32-bit word. wait: completes 0 when woken, -EAGAIN if *addr != expected,
 * -ETIMEDOUT after timeout_ns (negative = forever). wake: result = waiters woken. */
int oio_futex_wait(oio_loop *loop, oio_op *op, const uint32_t *addr, uint32_t expected, int64_t timeout_ns, oio_cb cb);
int oio_futex_wake(oio_loop *loop, oio_op *op, const uint32_t *addr, uint32_t count, oio_cb cb);
int oio_connect(oio_loop *loop, oio_op *op, oio_fd fd, const void *sockaddr, size_t addr_len, oio_cb cb);
/* result = new fd (close-on-exec). The peer address, if addr != NULL, is written to addr and its
 * size to op->aux. */
int oio_accept(oio_loop *loop, oio_op *op, oio_fd fd, void *addr, size_t addr_cap, oio_cb cb);
/* offset -1 = current position, otherwise preadv/pwritev. pread/pwrite are oio_read/oio_write
 * with a non-negative offset. The iovec array must stay valid until the callback. */
int oio_readv(oio_loop *loop, oio_op *op, oio_fd fd, const oio_iovec *iov, size_t iov_count, int64_t offset, oio_cb cb);
int oio_writev(oio_loop *loop, oio_op *op, oio_fd fd, const oio_iovec *iov, size_t iov_count, int64_t offset, oio_cb cb);
int oio_timeout(oio_loop *loop, oio_op *op, uint64_t ns, oio_cb cb);
/* 1 if the op was still cancellable, 0 otherwise; the callback runs either way. */
int oio_cancel(oio_loop *loop, oio_op *op);

/* Directory listing. cookie = 0 first, then the previous completion's op->aux. result = bytes
 * written into buf (0 = end, -ERANGE if the first entry does not fit; use >= 4096 bytes).
 * Entries are packed back to back, never split, "." and ".." skipped:
 *   uint8_t kind (0 other, 1 file, 2 dir, 3 symlink); uint16_t name_len (little endian); name bytes.
 * The cookie is the directory fd position: do not run two readdirs on one fd at once. */
int oio_readdir(oio_loop *loop, oio_op *op, oio_fd dirfd, void *buf, size_t len, uint64_t cookie, oio_cb cb);
int oio_ftruncate(oio_loop *loop, oio_op *op, oio_fd fd, uint64_t len, oio_cb cb);

#ifdef __cplusplus
}
#endif
#endif
