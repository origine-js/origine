//! The REPL's parsing and line editor for origine, behind a small C ABI (include/origine_repl.h).
//! Pure Rust: no terminal, no V8, no syscalls. The host (Zig) reads bytes from the terminal,
//! writes what the editor asks for, evaluates the code `origine_repl_prepare` hands back, and
//! answers completion requests from live objects.
//!
//! * `command`, `input`: dot-commands, pending multiline source and history.
//! * `analyze`, `rewrite`: types erased, unfinished input spotted, top-level `await`/`import`
//!   rewritten (all with the oxc parser).
//! * `keys`, `edit`, `editor`, `render`, `complete`: the readline-style line editor.
//!
//! Every entry point is panic-safe: a panic is reported as a failed result, never unwound across
//! the C boundary.

mod analyze;
mod command;
mod complete;
mod edit;
mod editor;
mod input;
mod keys;
mod render;
mod rewrite;

use std::ffi::c_void;
use std::panic::{AssertUnwindSafe, catch_unwind};

use analyze::Prepared;
use command::Command;
use editor::{Context, Editor, Event};
use input::Input;

const ABI_VERSION: u32 = 1;

const BUF_OUTPUT: u32 = 0;
const BUF_LINE: u32 = 1;
const BUF_SOURCE: u32 = 2;
const BUF_ARGUMENT: u32 = 3;
const BUF_CODE: u32 = 4;
const BUF_PLAIN: u32 = 5;
const BUF_DIAGNOSTICS: u32 = 6;

const CMD_SOURCE: u32 = 0;
const CMD_HELP: u32 = 1;
const CMD_EXIT: u32 = 2;
const CMD_CLEAR: u32 = 3;
const CMD_HISTORY: u32 = 4;
const CMD_AGAIN: u32 = 5;
const CMD_COMPLETE: u32 = 6;
const CMD_INVALID: u32 = 7;

const APPEND_OK: u32 = 0;
const APPEND_TOO_LONG: u32 = 1;

const PREPARED_SCRIPT: u32 = 0;
const PREPARED_ASYNC: u32 = 1;
const PREPARED_INCOMPLETE: u32 = 2;
const PREPARED_ERROR: u32 = 3;

const EDIT_CONTINUE: u32 = 0;
const EDIT_LINE: u32 = 1;
const EDIT_EOF: u32 = 2;
const EDIT_CANCELED: u32 = 3;

/// Mirrors `OrigineReplHost` in include/origine_repl.h.
#[repr(C)]
pub struct OrigineReplHost {
    ctx: *mut c_void,
    complete: Option<unsafe extern "C" fn(*mut c_void, *const u8, usize, *mut OrigineReplSink) -> bool>,
}

/// Opaque to C: collects the text of a completion callback.
pub struct OrigineReplSink(Vec<u8>);

/// Opaque to C: everything one REPL keeps between lines.
pub struct OrigineRepl {
    input: Input,
    editor: Editor,
    argument: Vec<u8>,
    code: Vec<u8>,
    plain: Vec<u8>,
    diagnostics: Vec<u8>,
}

// CONTRACT (docs/contracts.md, surface G): include/origine_repl.h is the source of truth.
// `header_abi.rs` is generated from it (`just gen-contracts`, checked by `just check-contracts`)
// and the block below makes this file fail to compile when the hand-written constants, the
// `#[repr(C)]` struct or the `extern "C"` functions drift from the header.
#[rustfmt::skip]
#[allow(dead_code, non_camel_case_types, clashing_extern_declarations, improper_ctypes, unsafe_op_in_unsafe_fn)]
mod header_abi;

mod abi_check {
    use super::*;
    use header_abi as h;
    use std::mem::{offset_of, size_of};

    const _: () = {
        assert!(ABI_VERSION == h::ORIGINE_REPL_ABI_VERSION);
        assert!(BUF_OUTPUT == h::ORIGINE_REPL_BUF_OUTPUT);
        assert!(BUF_LINE == h::ORIGINE_REPL_BUF_LINE);
        assert!(BUF_SOURCE == h::ORIGINE_REPL_BUF_SOURCE);
        assert!(BUF_ARGUMENT == h::ORIGINE_REPL_BUF_ARGUMENT);
        assert!(BUF_CODE == h::ORIGINE_REPL_BUF_CODE);
        assert!(BUF_PLAIN == h::ORIGINE_REPL_BUF_PLAIN);
        assert!(BUF_DIAGNOSTICS == h::ORIGINE_REPL_BUF_DIAGNOSTICS);
        assert!(CMD_SOURCE == h::ORIGINE_REPL_CMD_SOURCE);
        assert!(CMD_HELP == h::ORIGINE_REPL_CMD_HELP);
        assert!(CMD_EXIT == h::ORIGINE_REPL_CMD_EXIT);
        assert!(CMD_CLEAR == h::ORIGINE_REPL_CMD_CLEAR);
        assert!(CMD_HISTORY == h::ORIGINE_REPL_CMD_HISTORY);
        assert!(CMD_AGAIN == h::ORIGINE_REPL_CMD_AGAIN);
        assert!(CMD_COMPLETE == h::ORIGINE_REPL_CMD_COMPLETE);
        assert!(CMD_INVALID == h::ORIGINE_REPL_CMD_INVALID);
        assert!(APPEND_OK == h::ORIGINE_REPL_APPEND_OK);
        assert!(APPEND_TOO_LONG == h::ORIGINE_REPL_APPEND_TOO_LONG);
        assert!(PREPARED_SCRIPT == h::ORIGINE_REPL_PREPARED_SCRIPT);
        assert!(PREPARED_ASYNC == h::ORIGINE_REPL_PREPARED_ASYNC);
        assert!(PREPARED_INCOMPLETE == h::ORIGINE_REPL_PREPARED_INCOMPLETE);
        assert!(PREPARED_ERROR == h::ORIGINE_REPL_PREPARED_ERROR);
        assert!(EDIT_CONTINUE == h::ORIGINE_REPL_EDIT_CONTINUE);
        assert!(EDIT_LINE == h::ORIGINE_REPL_EDIT_LINE);
        assert!(EDIT_EOF == h::ORIGINE_REPL_EDIT_EOF);
        assert!(EDIT_CANCELED == h::ORIGINE_REPL_EDIT_CANCELED);
        // OrigineReplHost is the whole C struct.
        assert!(size_of::<OrigineReplHost>() == size_of::<h::c_view::OrigineReplHost>());
        assert!(offset_of!(OrigineReplHost, ctx) == offset_of!(h::c_view::OrigineReplHost, ctx));
        assert!(offset_of!(OrigineReplHost, complete) == offset_of!(h::c_view::OrigineReplHost, complete));
    };

    /// The array only type-checks when both fn items coerce to one fn pointer type.
    #[allow(dead_code)]
    fn signatures() {
        let _ = [h::origine_repl_abi_version, super::origine_repl_abi_version];
        let _ = [h::origine_repl_new, super::origine_repl_new];
        let _ = [h::origine_repl_free, super::origine_repl_free];
        let _ = [h::origine_repl_buffer, super::origine_repl_buffer];
        let _ = [h::origine_repl_sink_push, super::origine_repl_sink_push];
        let _ = [h::origine_repl_command, super::origine_repl_command];
        let _ = [h::origine_repl_append, super::origine_repl_append];
        let _ = [h::origine_repl_clear, super::origine_repl_clear];
        let _ = [h::origine_repl_remember, super::origine_repl_remember];
        let _ = [h::origine_repl_recall, super::origine_repl_recall];
        let _ = [h::origine_repl_history_len, super::origine_repl_history_len];
        let _ = [h::origine_repl_history_get, super::origine_repl_history_get];
        let _ = [h::origine_repl_prepare, super::origine_repl_prepare];
        let _ = [h::origine_repl_edit_begin, super::origine_repl_edit_begin];
        let _ = [h::origine_repl_edit_feed, super::origine_repl_edit_feed];
        let _ = [h::origine_repl_edit_timeout, super::origine_repl_edit_timeout];
        let _ = [h::origine_repl_edit_eof, super::origine_repl_edit_eof];
        let _ = [h::origine_repl_edit_in_sequence, super::origine_repl_edit_in_sequence];
    }
}

/// # Safety
/// `ptr` must be valid for `len` bytes when `len > 0`.
unsafe fn bytes<'a>(ptr: *const u8, len: usize) -> &'a [u8] {
    if len == 0 {
        return &[];
    }
    // SAFETY: `len > 0`, so the caller guarantees `ptr` is valid for `len` bytes.
    unsafe { std::slice::from_raw_parts(ptr, len) }
}

/// Hands a Rust slice to C: pointer and length (the pointer is dangling-but-nonnull for empty).
///
/// # Safety
/// `len` must be null or valid for a write.
unsafe fn give(data: &[u8], len: *mut usize) -> *const u8 {
    if !len.is_null() {
        // SAFETY: the caller guarantees a non-null `len` is valid for a write.
        unsafe { len.write(data.len()) };
    }
    data.as_ptr()
}

/// Runs `f`, turning a panic into `fallback`.
fn guard<T>(fallback: T, f: impl FnOnce() -> T) -> T {
    catch_unwind(AssertUnwindSafe(f)).unwrap_or(fallback)
}

#[unsafe(no_mangle)]
pub extern "C" fn origine_repl_abi_version() -> u32 {
    ABI_VERSION
}

#[unsafe(no_mangle)]
pub extern "C" fn origine_repl_new(colors: bool) -> *mut OrigineRepl {
    Box::into_raw(Box::new(OrigineRepl {
        input: Input::default(),
        editor: Editor::new(colors),
        argument: Vec::new(),
        code: Vec::new(),
        plain: Vec::new(),
        diagnostics: Vec::new(),
    }))
}

/// # Safety
/// `repl` must be null or come from `origine_repl_new` and not have been freed already.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn origine_repl_free(repl: *mut OrigineRepl) {
    if !repl.is_null() {
        // SAFETY: allocated by `origine_repl_new` through `Box::into_raw`, freed exactly once.
        drop(unsafe { Box::from_raw(repl) });
    }
}

/// # Safety
/// `repl` must be valid; `len` null or valid for a write.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn origine_repl_buffer(repl: *const OrigineRepl, which: u32, len: *mut usize) -> *const u8 {
    // SAFETY: the caller guarantees `repl` is valid.
    let repl = unsafe { &*repl };
    let data: &[u8] = match which {
        BUF_OUTPUT => repl.editor.output(),
        BUF_LINE => repl.editor.line().as_bytes(),
        BUF_SOURCE => repl.input.source().as_bytes(),
        BUF_ARGUMENT => &repl.argument,
        BUF_CODE => &repl.code,
        BUF_PLAIN => &repl.plain,
        BUF_DIAGNOSTICS => &repl.diagnostics,
        _ => &[],
    };
    // SAFETY: `len` is null or valid for a write, per the contract.
    unsafe { give(data, len) }
}

/// # Safety
/// `sink` must be the sink a completion callback was handed; `bytes` valid for `len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn origine_repl_sink_push(sink: *mut OrigineReplSink, data: *const u8, len: usize) {
    // SAFETY: the caller guarantees `data` is valid for `len` bytes.
    let data = unsafe { bytes(data, len) };
    // SAFETY: the caller guarantees `sink` is the live sink of the running callback.
    unsafe { &mut *sink }.0.extend_from_slice(data);
}

/// # Safety
/// `repl` must be valid; `line` valid for `len` bytes; `number` null or valid for a write.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn origine_repl_command(repl: *mut OrigineRepl, line: *const u8, len: usize, number: *mut usize) -> u32 {
    // SAFETY: the caller guarantees `repl` is valid and not used concurrently.
    let repl = unsafe { &mut *repl };
    // SAFETY: the caller guarantees `line` is valid for `len` bytes.
    let line = unsafe { bytes(line, len) };
    let (kind, value) = match command::parse(line) {
        Command::Source => (CMD_SOURCE, 0),
        Command::Help => (CMD_HELP, 0),
        Command::Exit => (CMD_EXIT, 0),
        Command::Clear => (CMD_CLEAR, 0),
        Command::History => (CMD_HISTORY, 0),
        Command::Again(n) => (CMD_AGAIN, n.unwrap_or(0)),
        Command::Complete(prefix) => {
            repl.argument = prefix.to_vec();
            (CMD_COMPLETE, 0)
        }
        Command::Invalid => (CMD_INVALID, 0),
    };
    if !number.is_null() {
        // SAFETY: the caller guarantees a non-null `number` is valid for a write.
        unsafe { number.write(value) };
    }
    kind
}

/// # Safety
/// `repl` must be valid; `line` valid for `len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn origine_repl_append(repl: *mut OrigineRepl, line: *const u8, len: usize) -> u32 {
    // SAFETY: the caller guarantees `repl` is valid and not used concurrently.
    let repl = unsafe { &mut *repl };
    // SAFETY: the caller guarantees `line` is valid for `len` bytes.
    let line = unsafe { bytes(line, len) };
    match repl.input.append(line) {
        Ok(()) => APPEND_OK,
        Err(input::TooLong) => APPEND_TOO_LONG,
    }
}

/// # Safety
/// `repl` must be valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn origine_repl_clear(repl: *mut OrigineRepl) {
    // SAFETY: the caller guarantees `repl` is valid and not used concurrently.
    unsafe { &mut *repl }.input.clear();
}

/// # Safety
/// `repl` must be valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn origine_repl_remember(repl: *mut OrigineRepl) {
    // SAFETY: the caller guarantees `repl` is valid and not used concurrently.
    unsafe { &mut *repl }.input.remember();
}

/// # Safety
/// `repl` must be valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn origine_repl_recall(repl: *mut OrigineRepl, number: usize) -> bool {
    // SAFETY: the caller guarantees `repl` is valid and not used concurrently.
    let repl = unsafe { &mut *repl };
    repl.input.recall((number != 0).then_some(number)).is_ok()
}

/// # Safety
/// `repl` must be valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn origine_repl_history_len(repl: *const OrigineRepl) -> usize {
    // SAFETY: the caller guarantees `repl` is valid.
    unsafe { &*repl }.input.history().len()
}

/// # Safety
/// `repl` must be valid; `len` null or valid for a write.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn origine_repl_history_get(repl: *const OrigineRepl, index: usize, len: *mut usize) -> *const u8 {
    // SAFETY: the caller guarantees `repl` is valid.
    let repl = unsafe { &*repl };
    let entry = repl.input.history().get(index).map_or(&[][..], String::as_bytes);
    // SAFETY: `len` is null or valid for a write, per the contract.
    unsafe { give(entry, len) }
}

/// # Safety
/// `repl` must be valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn origine_repl_prepare(repl: *mut OrigineRepl) -> u32 {
    // SAFETY: the caller guarantees `repl` is valid and not used concurrently.
    let repl = unsafe { &mut *repl };
    let prepared = guard(Prepared::Error(String::from("internal error: the parser panicked")), || analyze::prepare(repl.input.source()));
    repl.code.clear();
    repl.plain.clear();
    repl.diagnostics.clear();
    match prepared {
        Prepared::Ready { code, plain, asynchronous } => {
            repl.code = code.into_bytes();
            repl.plain = plain.into_bytes();
            if asynchronous { PREPARED_ASYNC } else { PREPARED_SCRIPT }
        }
        Prepared::Incomplete(diagnostics) => {
            repl.diagnostics = diagnostics.into_bytes();
            PREPARED_INCOMPLETE
        }
        Prepared::Error(diagnostics) => {
            repl.diagnostics = diagnostics.into_bytes();
            PREPARED_ERROR
        }
    }
}

/// # Safety
/// `repl` must be valid; `prompt` valid for `len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn origine_repl_edit_begin(repl: *mut OrigineRepl, prompt: *const u8, len: usize) {
    // SAFETY: the caller guarantees `repl` is valid and not used concurrently.
    let repl = unsafe { &mut *repl };
    // SAFETY: the caller guarantees `prompt` is valid for `len` bytes.
    let prompt = String::from_utf8_lossy(unsafe { bytes(prompt, len) });
    let history = repl.input.history().len();
    repl.editor.begin(&prompt, history);
}

/// Runs an editor call with the host's completion callback.
///
/// # Safety
/// `host` must be null or valid for the call.
unsafe fn drive(
    repl: &mut OrigineRepl,
    width: u32,
    host: *const OrigineReplHost,
    call: impl FnOnce(&mut Editor, &mut Context) -> Event,
) -> u32 {
    // SAFETY: the caller guarantees `host` is null or valid.
    let host = unsafe { host.as_ref() };
    let mut complete = |prefix: &str| -> Option<String> {
        let host = host?;
        let callback = host.complete?;
        let mut sink = OrigineReplSink(Vec::new());
        // SAFETY: the host's callback contract: `ctx` is its own, the prefix is valid for the call
        // and the sink lives until it returns.
        let ok = unsafe { callback(host.ctx, prefix.as_ptr(), prefix.len(), &mut sink) };
        ok.then(|| String::from_utf8_lossy(&sink.0).into_owned())
    };
    let OrigineRepl { input, editor, .. } = repl;
    let mut context = Context { width: width as usize, history: input.history(), pending: input.source(), complete: &mut complete };
    let event = guard(Event::Canceled, || call(editor, &mut context));
    match event {
        Event::Continue => EDIT_CONTINUE,
        Event::Line => EDIT_LINE,
        Event::Eof => EDIT_EOF,
        Event::Canceled => EDIT_CANCELED,
    }
}

/// # Safety
/// `repl` must be valid; `host` null or valid for the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn origine_repl_edit_feed(repl: *mut OrigineRepl, byte: u8, width: u32, host: *const OrigineReplHost) -> u32 {
    // SAFETY: the caller guarantees `repl` is valid and not used concurrently.
    let repl = unsafe { &mut *repl };
    // SAFETY: forwarded under the same contract.
    unsafe { drive(repl, width, host, |editor, context| editor.feed(byte, context)) }
}

/// # Safety
/// `repl` must be valid; `host` null or valid for the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn origine_repl_edit_timeout(repl: *mut OrigineRepl, width: u32, host: *const OrigineReplHost) -> u32 {
    // SAFETY: the caller guarantees `repl` is valid and not used concurrently.
    let repl = unsafe { &mut *repl };
    // SAFETY: forwarded under the same contract.
    unsafe { drive(repl, width, host, |editor, context| editor.timeout(context)) }
}

/// # Safety
/// `repl` must be valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn origine_repl_edit_eof(repl: *mut OrigineRepl) -> u32 {
    // SAFETY: the caller guarantees `repl` is valid and not used concurrently.
    let repl = unsafe { &mut *repl };
    match repl.editor.eof() {
        Event::Line => EDIT_LINE,
        _ => EDIT_EOF,
    }
}

/// # Safety
/// `repl` must be valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn origine_repl_edit_in_sequence(repl: *const OrigineRepl) -> bool {
    // SAFETY: the caller guarantees `repl` is valid.
    unsafe { &*repl }.editor.in_sequence()
}

#[cfg(test)]
mod tests {
    use super::*;

    unsafe extern "C" fn names(_: *mut c_void, prefix: *const u8, len: usize, sink: *mut OrigineReplSink) -> bool {
        // SAFETY: the editor passes a prefix valid for `len` bytes.
        let prefix = unsafe { bytes(prefix, len) };
        if !prefix.starts_with(b"Math.m") {
            return false;
        }
        let list = b"Math.max\nMath.min";
        // SAFETY: the editor passes the live sink of this callback.
        unsafe { origine_repl_sink_push(sink, list.as_ptr(), list.len()) };
        true
    }

    /// The C API through safe methods, one unsafe operation each.
    struct Handle(*mut OrigineRepl);

    impl Handle {
        fn new(colors: bool) -> Self {
            Handle(origine_repl_new(colors))
        }

        fn begin(&self, prompt: &str) {
            // SAFETY: `self.0` is live until drop; the prompt is valid for its length.
            unsafe { origine_repl_edit_begin(self.0, prompt.as_ptr(), prompt.len()) }
        }

        fn feed(&self, byte: u8, host: Option<&OrigineReplHost>) -> u32 {
            let host = host.map_or(std::ptr::null(), std::ptr::from_ref);
            // SAFETY: `self.0` is live; `host` is null or borrowed for the call.
            unsafe { origine_repl_edit_feed(self.0, byte, 80, host) }
        }

        fn type_text(&self, text: &str, host: Option<&OrigineReplHost>) -> u32 {
            let mut last = EDIT_CONTINUE;
            for byte in text.bytes() {
                last = self.feed(byte, host);
            }
            last
        }

        fn append(&self, line: &str) -> u32 {
            // SAFETY: `self.0` is live; the line is valid for its length.
            unsafe { origine_repl_append(self.0, line.as_ptr(), line.len()) }
        }

        /// Appends `source` as the pending input (after clearing it) and prepares it.
        fn prepare(&self, source: &str) -> u32 {
            // SAFETY: `self.0` is live.
            unsafe { origine_repl_clear(self.0) };
            self.append(source);
            // SAFETY: `self.0` is live.
            unsafe { origine_repl_prepare(self.0) }
        }

        fn command(&self, line: &str, number: &mut usize) -> u32 {
            // SAFETY: `self.0` is live; the line is valid for its length; `number` is a live reference.
            unsafe { origine_repl_command(self.0, line.as_ptr(), line.len(), number) }
        }

        fn remember(&self) {
            // SAFETY: `self.0` is live.
            unsafe { origine_repl_remember(self.0) }
        }

        fn recall(&self, number: usize) -> bool {
            // SAFETY: `self.0` is live.
            unsafe { origine_repl_recall(self.0, number) }
        }

        fn history_len(&self) -> usize {
            // SAFETY: `self.0` is live.
            unsafe { origine_repl_history_len(self.0) }
        }

        fn text(&self, which: u32) -> String {
            let mut len = 0;
            // SAFETY: `self.0` is live and `len` is a local.
            let ptr = unsafe { origine_repl_buffer(self.0, which, &mut len) };
            // SAFETY: the buffer is valid for `len` bytes until the next call.
            String::from_utf8_lossy(unsafe { bytes(ptr, len) }).into_owned()
        }
    }

    impl Drop for Handle {
        fn drop(&mut self) {
            // SAFETY: created by `origine_repl_new`, freed once.
            unsafe { origine_repl_free(self.0) }
        }
    }

    #[test]
    fn the_c_api_runs_a_line_through_the_editor_and_the_parser() {
        let repl = Handle::new(false);
        repl.begin("> ");
        assert_eq!(repl.type_text("1 + 1\r", None), EDIT_LINE);
        assert_eq!(repl.text(BUF_LINE), "1 + 1");
        assert_eq!(repl.append("1 + 1"), APPEND_OK);
        assert_eq!(repl.text(BUF_SOURCE), "1 + 1");
        assert_eq!(repl.prepare("1 + 1"), PREPARED_SCRIPT);
        assert_eq!(repl.text(BUF_CODE), repl.text(BUF_PLAIN));
        repl.remember();
        assert_eq!(repl.history_len(), 1);
        assert!(repl.recall(0));
        assert!(!repl.recall(2));
        assert_eq!(repl.prepare("function f("), PREPARED_INCOMPLETE);
        assert_eq!(repl.prepare("let = = 1"), PREPARED_ERROR);
        assert!(repl.text(BUF_DIAGNOSTICS).contains(": error: "));
        assert_eq!(repl.prepare("await 1"), PREPARED_ASYNC);
    }

    #[test]
    fn completions_come_from_the_host_callback() {
        let repl = Handle::new(true);
        let host = OrigineReplHost { ctx: std::ptr::null_mut(), complete: Some(names) };
        repl.begin("> ");
        repl.type_text("Math.ma", Some(&host));
        assert!(repl.text(BUF_OUTPUT).contains("\x1b[2mx\x1b[0m"), "{}", repl.text(BUF_OUTPUT));
        assert_eq!(repl.feed(b'\t', None), EDIT_CONTINUE);
        assert_eq!(repl.feed(b'\r', None), EDIT_LINE);
        assert_eq!(repl.text(BUF_LINE), "Math.max");
    }

    #[test]
    fn commands_report_their_arguments() {
        let repl = Handle::new(false);
        let mut number = 7;
        assert_eq!(repl.command(".again 3", &mut number), CMD_AGAIN);
        assert_eq!(number, 3);
        assert_eq!(repl.command(".complete Ma", &mut number), CMD_COMPLETE);
        assert_eq!(repl.text(BUF_ARGUMENT), "Ma");
        assert_eq!(repl.command("1", &mut number), CMD_SOURCE);
    }
}
