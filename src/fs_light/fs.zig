//! The root of the vendored Zig 0.15.2 `std.fs` primitives (see README.md): what `Dir.zig`,
//! `File.zig` and `posix.zig` expect to find in `std.fs`.
const std = @import("std");
const builtin = @import("builtin");
pub const posix = @import("posix.zig");
pub const windows = @import("windows.zig");
pub const File = @import("File.zig");
pub const Dir = @import("Dir.zig");
pub const windows_handles = builtin.os.tag == .windows;
pub const path = std.fs.path;
pub const max_path_bytes = posix.PATH_MAX;
pub const max_name_bytes = switch (builtin.os.tag) {
    .linux, .macos, .ios, .freebsd, .openbsd, .netbsd, .dragonfly => 255,
    .windows => 255,
    else => 255,
};
pub const base64_encoder = std.base64.Base64Encoder.init(std.base64.url_safe_alphabet_chars, null);

/// The process's working directory.
pub fn cwd() Dir {
    if (builtin.os.tag == .windows) {
        return .{ .fd = windows.peb().ProcessParameters.CurrentDirectory.Handle };
    } else {
        return .{ .fd = posix.AT.FDCWD };
    }
}
