//! Host file system and terminal access without `std.Io`: `std.Io.Dir` and `std.Io.File` as of Zig
//! 0.17 (same names, options and error names) minus the `io` parameter, over the Zig 0.15.2
//! `std.fs` primitives vendored in `src/fs_light/`.
//!
//! `std.Io.Threaded` brings every `Io` operation with it (sockets, processes, a thread pool) for
//! the sake of the few dozen file calls the Zig side makes; the Rust runtime does the asynchronous
//! work. Everything here is blocking. Where 0.17 reports something 0.15 does not record, the field
//! is left out rather than made up: `Stat` has no `nlink` or `block_size`, `Dir.Entry` no `inode`.
//! `std.Io.Reader`, `Writer`, `Limit` and `Timestamp` are plain data and are used as they are.
const std = @import("std");
const builtin = @import("builtin");
const fs_light = @import("../fs_light/fs.zig");
/// The vendored primitives themselves, for what this facade does not wrap.
pub const light = fs_light;
const posix = fs_light.posix;
const windows = fs_light.windows;
const is_windows = builtin.os.tag == .windows;

pub const max_path_bytes = fs_light.max_path_bytes;
pub const Limit = std.Io.Limit;
pub const Timestamp = std.Io.Timestamp;

pub const Permissions = struct {
    mode: fs_light.File.Mode,

    pub const default_file: Permissions = .{ .mode = if (is_windows) 0 else 0o666 };
    pub const default_dir: Permissions = .{ .mode = if (is_windows) 0 else 0o777 };
};

pub const File = struct {
    handle: Handle,

    pub const Handle = fs_light.File.Handle;
    pub const Kind = fs_light.File.Kind;
    pub const INode = fs_light.File.INode;
    pub const Mode = enum { read_only, write_only, read_write };

    pub const Stat = struct {
        inode: INode,
        size: u64,
        permissions: Permissions,
        kind: Kind,
        atime: ?Timestamp,
        mtime: Timestamp,
        ctime: Timestamp,
    };

    pub const StatError = fs_light.File.StatError;
    pub const OpenError = fs_light.File.OpenError;
    pub const ReadStreamingError = fs_light.File.ReadError || error{EndOfStream};
    pub const ReadPositionalError = fs_light.File.PReadError;
    pub const WriteError = fs_light.File.WriteError;

    fn inner(self: File) fs_light.File {
        return .{ .handle = self.handle };
    }

    fn statOf(st: fs_light.File.Stat) Stat {
        return .{
            .inode = st.inode,
            .size = st.size,
            .permissions = .{ .mode = st.mode },
            .kind = st.kind,
            .atime = .{ .nanoseconds = @intCast(st.atime) },
            .mtime = .{ .nanoseconds = @intCast(st.mtime) },
            .ctime = .{ .nanoseconds = @intCast(st.ctime) },
        };
    }

    pub fn stdin() File {
        return .{ .handle = if (is_windows) windows.peb().ProcessParameters.hStdInput else posix.STDIN_FILENO };
    }

    pub fn stdout() File {
        return .{ .handle = if (is_windows) windows.peb().ProcessParameters.hStdOutput else posix.STDOUT_FILENO };
    }

    pub fn stderr() File {
        return .{ .handle = if (is_windows) windows.peb().ProcessParameters.hStdError else posix.STDERR_FILENO };
    }

    pub fn close(file: File) void {
        file.inner().close();
    }

    pub fn stat(file: File) StatError!Stat {
        return statOf(try file.inner().stat());
    }

    pub fn sync(file: File) fs_light.File.SyncError!void {
        return file.inner().sync();
    }

    pub fn isTty(file: File) error{}!bool {
        return file.inner().isTty();
    }

    pub fn setLength(file: File, new_length: u64) fs_light.File.SetEndPosError!void {
        return file.inner().setEndPos(new_length);
    }

    /// One read into the first non-empty buffer; `error.EndOfStream` at the end of the file.
    pub fn readStreaming(file: File, buffer: []const []u8) ReadStreamingError!usize {
        for (buffer) |chunk| {
            if (chunk.len == 0) continue;
            const count = try file.inner().read(chunk);
            if (count == 0) return error.EndOfStream;
            return count;
        }
        return 0;
    }

    /// One read at `offset` into the first non-empty buffer; 0 at or past the end of the file.
    pub fn readPositional(file: File, buffer: []const []u8, offset: u64) ReadPositionalError!usize {
        for (buffer) |chunk| {
            if (chunk.len == 0) continue;
            return file.inner().pread(chunk, offset);
        }
        return 0;
    }

    /// Fills `buffer` from `offset` unless the file ends first; returns the byte count.
    pub fn readPositionalAll(file: File, buffer: []u8, offset: u64) ReadPositionalError!usize {
        return file.inner().preadAll(buffer, offset);
    }

    pub fn writePositionalAll(file: File, bytes: []const u8, offset: u64) fs_light.File.PWriteError!void {
        return file.inner().pwriteAll(bytes, offset);
    }

    /// `header`, then `data` (its last element `splat` times). A single chunk goes out in one write
    /// that may be partial, and the result counts bytes of `data`; anything else is written whole.
    pub fn writeStreaming(file: File, header: []const u8, data: []const []const u8, splat: usize) WriteError!usize {
        if (header.len != 0) try file.inner().writeAll(header);
        if (data.len == 1 and splat == 1) {
            if (data[0].len == 0) return 0;
            return file.inner().write(data[0]);
        }
        var total: usize = 0;
        for (data[0 .. data.len - 1]) |chunk| {
            try file.inner().writeAll(chunk);
            total += chunk.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| try file.inner().writeAll(last);
        return total + last.len * splat;
    }

    pub fn writeStreamingAll(file: File, bytes: []const u8) WriteError!void {
        return file.inner().writeAll(bytes);
    }

    pub const MemoryMap = struct {
        /// The mapped bytes (read-only unless created with `protection.write`).
        memory: []align(std.heap.page_size_min) u8,
        /// False when the platform has no mapping and `memory` is a copy.
        mapped: bool,

        pub const CreateOptions = struct {
            len: usize,
            protection: struct { read: bool = false, write: bool = false } = .{},
        };
        pub const CreateError = posix.MMapError || ReadPositionalError || error{OutOfMemory};

        pub fn destroy(map: *MemoryMap) void {
            if (!is_windows and map.mapped) posix.munmap(map.memory) else std.heap.page_allocator.free(map.memory);
            map.* = undefined;
        }
    };

    /// Maps the first `options.len` bytes (> 0); where the platform cannot, reads them into memory.
    pub fn createMemoryMap(file: File, options: MemoryMap.CreateOptions) MemoryMap.CreateError!MemoryMap {
        if (is_windows) {
            const memory = try std.heap.page_allocator.alignedAlloc(u8, .fromByteUnits(std.heap.page_size_min), options.len);
            errdefer std.heap.page_allocator.free(memory);
            _ = try file.readPositionalAll(memory, 0);
            return .{ .memory = memory, .mapped = false };
        }
        const protection: posix.system.PROT = .{ .READ = options.protection.read, .WRITE = options.protection.write };
        const memory = try posix.mmap(null, options.len, protection, .{ .TYPE = .PRIVATE }, file.handle, 0);
        return .{ .memory = memory, .mapped = true };
    }

    pub fn reader(file: File, buffer: []u8) Reader {
        return .{ .file = file, .interface = .{ .vtable = &.{ .stream = Reader.stream }, .buffer = buffer, .seek = 0, .end = 0 } };
    }

    pub fn writerStreaming(file: File, buffer: []u8) Writer {
        return .{ .file = file, .interface = .{ .vtable = &.{ .drain = Writer.drain }, .buffer = buffer } };
    }

    /// A `std.Io.Reader` over a file's streaming reads. Pin it before use: the interface finds its
    /// file through `@fieldParentPtr`.
    pub const Reader = struct {
        file: File,
        interface: std.Io.Reader,

        fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
            const self: *Reader = @alignCast(@fieldParentPtr("interface", r));
            const dest = limit.slice(try w.writableSliceGreedy(1));
            const count = self.file.inner().read(dest) catch return error.ReadFailed;
            if (count == 0) return error.EndOfStream;
            w.advance(count);
            return count;
        }
    };

    /// A `std.Io.Writer` over a file's streaming writes. Pin it before use, like `Reader`.
    pub const Writer = struct {
        file: File,
        interface: std.Io.Writer,

        fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const self: *Writer = @alignCast(@fieldParentPtr("interface", w));
            self.file.writeStreamingAll(w.buffered()) catch return error.WriteFailed;
            w.end = 0;
            return self.file.writeStreaming("", data, splat) catch error.WriteFailed;
        }
    };
};

pub const Dir = struct {
    handle: Handle,

    pub const Handle = fs_light.Dir.Handle;
    pub const Stat = File.Stat;
    pub const StatError = File.StatError;
    pub const Entry = struct { name: []const u8, kind: File.Kind };

    pub const OpenOptions = struct {
        access_sub_paths: bool = true,
        iterate: bool = false,
        follow_symlinks: bool = true,
    };

    pub const OpenFileOptions = struct {
        mode: File.Mode = .read_only,
        /// Opening a directory fails with `IsDir` when this is false.
        allow_directory: bool = true,
    };

    pub const CreateFileOptions = struct {
        read: bool = false,
        truncate: bool = true,
        exclusive: bool = false,
        permissions: Permissions = .default_file,
    };

    pub const WriteFileOptions = struct {
        sub_path: []const u8,
        data: []const u8,
        flags: CreateFileOptions = .{},
    };

    pub const StatFileOptions = struct {
        /// On Windows a final symlink is always followed.
        follow_symlinks: bool = true,
    };

    fn inner(self: Dir) fs_light.Dir {
        return .{ .fd = self.handle };
    }

    pub fn cwd() Dir {
        return .{ .handle = fs_light.cwd().fd };
    }

    pub fn close(self: Dir) void {
        var dir = self.inner();
        dir.close();
    }

    pub fn openDir(self: Dir, sub_path: []const u8, options: OpenOptions) fs_light.Dir.OpenError!Dir {
        const opened = try self.inner().openDir(sub_path, .{
            .access_sub_paths = options.access_sub_paths,
            .iterate = options.iterate,
            .no_follow = !options.follow_symlinks,
        });
        return .{ .handle = opened.fd };
    }

    pub fn openFile(self: Dir, sub_path: []const u8, options: OpenFileOptions) File.OpenError!File {
        const opened = try self.inner().openFile(sub_path, .{ .mode = switch (options.mode) {
            .read_only => .read_only,
            .write_only => .write_only,
            .read_write => .read_write,
        } });
        const file: File = .{ .handle = opened.handle };
        if (!options.allow_directory) {
            errdefer file.close();
            if ((file.stat() catch return error.Unexpected).kind == .directory) return error.IsDir;
        }
        return file;
    }

    pub fn createFile(self: Dir, sub_path: []const u8, options: CreateFileOptions) File.OpenError!File {
        const created = try self.inner().createFile(sub_path, .{
            .read = options.read,
            .truncate = options.truncate,
            .exclusive = options.exclusive,
            .mode = options.permissions.mode,
        });
        return .{ .handle = created.handle };
    }

    pub fn writeFile(self: Dir, options: WriteFileOptions) (File.OpenError || File.WriteError)!void {
        const file = try self.createFile(options.sub_path, options.flags);
        defer file.close();
        try file.writeStreamingAll(options.data);
    }

    pub fn readFileAlloc(self: Dir, sub_path: []const u8, gpa: std.mem.Allocator, limit: Limit) ![]u8 {
        return self.readFileAllocOptions(sub_path, gpa, limit, .of(u8), null);
    }

    /// The whole file. A file of `limit` bytes or more is `error.StreamTooLong`.
    pub fn readFileAllocOptions(
        self: Dir,
        sub_path: []const u8,
        gpa: std.mem.Allocator,
        limit: Limit,
        comptime alignment: std.mem.Alignment,
        comptime sentinel: ?u8,
    ) !(if (sentinel) |s| [:s]align(alignment.toByteUnits()) u8 else []align(alignment.toByteUnits()) u8) {
        const max: usize = switch (limit) {
            .unlimited => std.math.maxInt(usize),
            else => @backingInt(limit) -| 1,
        };
        return self.inner().readFileAllocOptions(gpa, sub_path, max, null, alignment, sentinel) catch |err| switch (err) {
            error.FileTooBig => error.StreamTooLong,
            else => |other| other,
        };
    }

    pub fn stat(self: Dir) StatError!Stat {
        return File.statOf(try self.inner().stat());
    }

    pub fn statFile(self: Dir, sub_path: []const u8, options: StatFileOptions) fs_light.Dir.StatFileError!Stat {
        return File.statOf(try self.inner().statFileFollowing(sub_path, options.follow_symlinks));
    }

    pub fn createDir(self: Dir, sub_path: []const u8, permissions: Permissions) fs_light.Dir.MakeError!void {
        if (is_windows) return self.inner().makeDir(sub_path);
        return posix.mkdirat(self.handle, sub_path, permissions.mode);
    }

    pub fn createDirPath(self: Dir, sub_path: []const u8) (fs_light.Dir.MakeError || fs_light.Dir.StatFileError)!void {
        return self.inner().makePath(sub_path);
    }

    pub fn deleteFile(self: Dir, sub_path: []const u8) fs_light.Dir.DeleteFileError!void {
        return self.inner().deleteFile(sub_path);
    }

    pub fn deleteDir(self: Dir, sub_path: []const u8) fs_light.Dir.DeleteDirError!void {
        return self.inner().deleteDir(sub_path);
    }

    pub fn deleteTree(self: Dir, sub_path: []const u8) fs_light.Dir.DeleteTreeError!void {
        return self.inner().deleteTree(sub_path);
    }

    /// Renames `old_sub_path` in this directory to `new_sub_path` in `new_dir`.
    pub fn rename(old_dir: Dir, old_sub_path: []const u8, new_dir: Dir, new_sub_path: []const u8) fs_light.Dir.RenameError!void {
        return posix.renameat(old_dir.handle, old_sub_path, new_dir.handle, new_sub_path);
    }

    pub const Iterator = struct {
        state: fs_light.Dir.Iterator,

        pub const Error = fs_light.Dir.Iterator.Error;

        /// The next entry other than `.` and `..`; its name lives until the next call.
        pub fn next(it: *Iterator) Error!?Entry {
            const entry = (try it.state.next()) orelse return null;
            return .{ .name = entry.name, .kind = entry.kind };
        }
    };

    /// A listing from the start of the directory, whatever happened to this handle before.
    pub fn iterate(self: Dir) Iterator {
        var it: Iterator = .{ .state = self.inner().iterate() };
        it.state.reset();
        return it;
    }
};

extern "c" fn proc_pidpath(pid: c_int, buffer: [*]u8, size: u32) c_int;

/// The path of the running executable written to `buffer`; returns its length.
pub fn executablePath(buffer: []u8) error{ Unsupported, NameTooLong }!usize {
    switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => {
            // Reports the length it wrote, unlike `_NSGetExecutablePath`.
            const rc = proc_pidpath(std.c.getpid(), buffer.ptr, @intCast(buffer.len));
            if (rc <= 0) return error.Unsupported;
            return @intCast(rc);
        },
        .windows => {
            const name = windows.peb().ProcessParameters.ImagePathName;
            const wide = name.Buffer.?[0 .. name.Length / 2];
            var utf8: [fs_light.max_path_bytes]u8 = undefined;
            const len = std.unicode.wtf16LeToWtf8(&utf8, wide);
            if (len > buffer.len) return error.NameTooLong;
            @memcpy(buffer[0..len], utf8[0..len]);
            return len;
        },
        else => {
            const path = posix.readlink("/proc/self/exe", buffer) catch return error.Unsupported;
            return path.len;
        },
    }
}
