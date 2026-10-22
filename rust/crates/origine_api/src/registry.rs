//! The natives registry: every `#[native(path = "namespace.name")]` fn, in one table that Zig
//! iterates (`origine_api_natives_count` / `origine_api_natives_get`, `include/origine_api.h`) to
//! build the `native` object the glue consumes. Zig has no list of its own.
//!
//! CONTRACT (docs/contracts.md, surface B): a new native is `#[native(path = "ns.name", ..)]` plus
//! one line in [`NATIVES`]. The test below fails when a `#[native]` fn is missing from the table (it
//! scans the module sources), when a path is duplicated, or when a path is not `namespace.name`.
//! The JS side (`src/js/glue/*.js`) must use exactly these names; `src/tests/managed/api.zig`
//! checks that every registered native is reachable from the glue's `native.<ns>.<name>` uses.

use std::ffi::{CString, c_int};
use std::sync::OnceLock;

use crate::abi_gen::{self, origine_api_native};
use crate::native::{Needs, RawNative, SideEffect};
use crate::{fs, io, net};

/// Every native, in registration order.
pub(crate) static NATIVES: &[RawNative] = &[
    io::NATIVE_IO_CREATE,
    io::NATIVE_IO_CLOSE,
    fs::NATIVE_FS_ASYNC_REQUEST,
    fs::NATIVE_FS_ASYNC_OPEN_FILE,
    fs::NATIVE_FS_ASYNC_OPEN_DIR,
    fs::NATIVE_FS_ASYNC_STAT,
    fs::NATIVE_FS_ASYNC_CREATE_DIR,
    fs::NATIVE_FS_ASYNC_DELETE_FILE,
    fs::NATIVE_FS_ASYNC_READ_DIR,
    fs::NATIVE_FS_ASYNC_READ_ALL,
    fs::NATIVE_FS_ASYNC_WRITE_ALL,
    fs::NATIVE_FS_ASYNC_CLOSE,
    fs::NATIVE_FS_ASYNC_CLOSE_DIR,
    fs::NATIVE_FS_ASYNC_CREATE_DIR_PATH,
    fs::NATIVE_FS_ASYNC_DELETE_DIR,
    fs::NATIVE_FS_ASYNC_DELETE_TREE,
    fs::NATIVE_FS_ASYNC_RENAME,
    fs::NATIVE_FS_ASYNC_FILE_STAT,
    fs::NATIVE_FS_ASYNC_FILE_READ,
    fs::NATIVE_FS_ASYNC_FILE_PREAD,
    fs::NATIVE_FS_ASYNC_FILE_READ_INTO,
    fs::NATIVE_FS_ASYNC_FILE_PREAD_INTO,
    fs::NATIVE_FS_ASYNC_FILE_READ_ALLOC,
    fs::NATIVE_FS_ASYNC_FILE_PREAD_ALLOC,
    fs::NATIVE_FS_ASYNC_FILE_WRITE,
    fs::NATIVE_FS_ASYNC_FILE_PWRITE_ALL,
    fs::NATIVE_FS_ASYNC_FILE_SET_LENGTH,
    fs::NATIVE_FS_ASYNC_FILE_SYNC,
    net::NATIVE_NET_LISTEN,
    net::NATIVE_NET_ACCEPT,
    net::NATIVE_NET_CONNECT,
    net::NATIVE_NET_READ,
    net::NATIVE_NET_READ_COPY,
    net::NATIVE_NET_READ_INTO,
    net::NATIVE_NET_WRITE,
    net::NATIVE_NET_CLOSE,
];

// The Rust enums are written out in the header's numbers.
const _: () = {
    assert!(SideEffect::None as u32 == abi_gen::ORIGINE_API_SIDE_NONE);
    assert!(SideEffect::Receiver as u32 == abi_gen::ORIGINE_API_SIDE_RECEIVER);
    assert!(SideEffect::Any as u32 == abi_gen::ORIGINE_API_SIDE_ANY);
    assert!(Needs::None as u32 == abi_gen::ORIGINE_API_NEEDS_NONE);
    assert!(Needs::Runtime as u32 == abi_gen::ORIGINE_API_NEEDS_RUNTIME);
    assert!(Needs::AsyncFs as u32 == abi_gen::ORIGINE_API_NEEDS_ASYNC_FS);
};

/// NUL-terminated copies of the paths, built once; C gets pointers into them.
fn c_paths() -> &'static [CString] {
    static PATHS: OnceLock<Vec<CString>> = OnceLock::new();
    PATHS.get_or_init(|| NATIVES.iter().map(|native| CString::new(native.path).expect("paths have no NUL")).collect())
}

/// Number of natives in the registry.
#[unsafe(no_mangle)]
pub extern "C" fn origine_api_natives_count() -> usize {
    NATIVES.len()
}

/// Fills `out` with native `index`; returns 0, or -1 when `index` is out of range.
///
/// # Safety
///
/// `out` must be valid for writing one `origine_api_native`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn origine_api_natives_get(index: usize, out: *mut origine_api_native) -> c_int {
    let Some(native) = NATIVES.get(index) else { return -1 };
    let path = c_paths()[index].as_ptr();
    // SAFETY: `unsafe extern "C" fn(*const FunctionCallbackInfo)` and `extern "C" fn(*const c_void)`
    // take one pointer and return nothing, the same ABI; V8 passes the callback info pointer.
    let callback = unsafe {
        std::mem::transmute::<unsafe extern "C" fn(*const v8::FunctionCallbackInfo), unsafe extern "C" fn(*const std::ffi::c_void)>(
            native.callback,
        )
    };
    // SAFETY: the caller guarantees `out` is valid for one write.
    unsafe {
        out.write(origine_api_native {
            path,
            callback: Some(callback),
            side_effect: native.side_effect as u32,
            needs: native.needs as u32,
        });
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;
    use std::ffi::CStr;

    /// Every `#[native(...)]` fn of `source` (its snake_case name).
    fn native_fns(source: &str) -> Vec<String> {
        let mut names = Vec::new();
        let mut lines = source.lines();
        while let Some(line) = lines.next() {
            if line.trim_start().starts_with("#[native(") {
                let decl = lines.by_ref().find(|l| l.contains("fn ")).expect("fn after #[native]");
                let after = &decl[decl.find("fn ").unwrap() + 3..];
                names.push(after.split(['(', '<']).next().unwrap().trim().to_owned());
            }
        }
        names
    }

    #[test]
    fn every_native_fn_is_registered_once() {
        let registry = include_str!("registry.rs");
        let mut found = 0;
        for (module, source) in [("io", include_str!("io.rs")), ("fs", include_str!("fs.rs")), ("net", include_str!("net.rs"))] {
            for name in native_fns(source) {
                let entry = format!("{module}::NATIVE_{},", name.to_uppercase());
                assert_eq!(registry.matches(&entry).count(), 1, "{name} must be listed exactly once in NATIVES");
                found += 1;
            }
        }
        assert_eq!(found, NATIVES.len(), "NATIVES lists something that is not a #[native] fn");
    }

    #[test]
    fn paths_are_unique_and_namespaced() {
        let mut seen = HashSet::new();
        for native in NATIVES {
            let (namespace, name) = native.path.split_once('.').expect("namespace.name");
            assert!(!namespace.is_empty() && !name.is_empty() && !name.contains('.'), "{}", native.path);
            assert!(seen.insert(native.path), "duplicate path {}", native.path);
        }
    }

    #[test]
    fn the_c_table_reports_the_registry() {
        assert_eq!(origine_api_natives_count(), NATIVES.len());
        let mut out = origine_api_native::default();
        // SAFETY: `out` is a valid destination.
        assert_eq!(unsafe { origine_api_natives_get(0, &mut out) }, 0);
        // SAFETY: `path` was just produced by `origine_api_natives_get` as a NUL-terminated string.
        assert_eq!(unsafe { CStr::from_ptr(out.path) }.to_str().unwrap(), NATIVES[0].path);
        // SAFETY: as above.
        assert_eq!(unsafe { origine_api_natives_get(NATIVES.len(), &mut out) }, -1);
    }
}
