//! Lexical path validation for capability-style access (mirrors `cleanPath` in `src/api/fs.zig`).

use std::io;
use std::path::Path;

fn invalid(msg: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, msg)
}

#[cfg(unix)]
fn bytes(p: &Path) -> io::Result<&[u8]> {
    Ok(std::os::unix::ffi::OsStrExt::as_bytes(p.as_os_str()))
}

#[cfg(not(unix))]
fn bytes(p: &Path) -> io::Result<&[u8]> {
    p.to_str().map(str::as_bytes).ok_or_else(|| invalid("path is not valid UTF-8"))
}

/// Check that `p` stays inside the directory it is resolved against, and return it unchanged.
///
/// Rejected with [`io::ErrorKind::InvalidInput`]: a NUL byte, an absolute path (leading `/`),
/// and any `..` component. The empty path and `.` components are accepted (the OS decides what
/// they mean for an operation: `open_dir("")` fails with `NotFound`, `open_dir(".")` works).
///
/// This is *lexical* only: a symlink inside the directory that points outside of it is still
/// followed by the OS. The check is on the raw bytes, so `a//b`, `./a` and `a/` are fine.
pub fn sanitize(p: &Path) -> io::Result<&Path> {
    let b = bytes(p)?;
    if b.contains(&0) {
        return Err(invalid("path contains a NUL byte"));
    }
    if b.first() == Some(&b'/') {
        return Err(invalid("absolute paths are not allowed"));
    }
    #[cfg(not(unix))]
    if p.has_root() || p.components().next().is_some_and(|c| matches!(c, std::path::Component::Prefix(_))) {
        return Err(invalid("absolute paths are not allowed"));
    }
    if b.split(|&c| c == b'/').any(|part| part == b"..") {
        return Err(invalid("`..` components are not allowed"));
    }
    Ok(p)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ok(s: &str) {
        assert!(sanitize(Path::new(s)).is_ok(), "{s:?} should be accepted");
    }

    fn bad(p: &Path) {
        let e = sanitize(p).unwrap_err();
        assert_eq!(e.kind(), io::ErrorKind::InvalidInput, "{p:?}");
    }

    #[test]
    fn accepts_relative() {
        for s in ["", ".", "./", "a", "a/b/c", "./a", "a//b", "a/", "a/./b", "..a", "a..", "a/..b/c", "...", ".hidden", "a b/ü"] {
            ok(s);
        }
    }

    #[test]
    fn rejects_escapes() {
        for s in ["/", "/etc/passwd", "//x", "..", "../a", "a/..", "a/../b", "a/b/../../..", "./..", "a/../", "../"] {
            bad(Path::new(s));
        }
    }

    #[test]
    fn rejects_nul() {
        bad(Path::new("a\0b"));
        bad(Path::new("\0"));
        bad(Path::new("ok/\0"));
    }

    #[cfg(unix)]
    #[test]
    fn non_utf8_is_fine() {
        use std::os::unix::ffi::OsStrExt;
        let p = Path::new(std::ffi::OsStr::from_bytes(b"a/\xff\xfe"));
        assert!(sanitize(p).is_ok());
        bad(Path::new(std::ffi::OsStr::from_bytes(b"\xff/../x")));
    }

    #[test]
    fn returns_input_unchanged() {
        let p = Path::new("a//b/");
        assert_eq!(sanitize(p).unwrap(), p);
    }
}
