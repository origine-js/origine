// C ABI of the origine_repl crate (the REPL's parsing and line editor). Linked from
// liborigine_native.a. The REPL is one opaque OrigineRepl; it never touches the terminal or V8.
// Ownership: inputs are borrowed for the duration of the call. Pointers returned by
// origine_repl_buffer and origine_repl_history_get belong to the OrigineRepl and stay valid until
// the next call on it that changes that buffer (any other call may invalidate them: copy first).
#ifndef ORIGINE_REPL_H
#define ORIGINE_REPL_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define ORIGINE_REPL_ABI_VERSION 1u

typedef struct OrigineRepl OrigineRepl;
// Collects text a callback hands back (see OrigineReplHost.complete).
typedef struct OrigineReplSink OrigineReplSink;

// Which text origine_repl_buffer returns.
enum {
  ORIGINE_REPL_BUF_OUTPUT = 0,       // bytes the line editor wants written to the terminal
  ORIGINE_REPL_BUF_LINE = 1,         // the line the editor finished
  ORIGINE_REPL_BUF_SOURCE = 2,       // pending (multiline) source
  ORIGINE_REPL_BUF_ARGUMENT = 3,     // argument of the last ORIGINE_REPL_CMD_COMPLETE
  ORIGINE_REPL_BUF_CODE = 4,         // what origine_repl_prepare wants run
  ORIGINE_REPL_BUF_PLAIN = 5,        // the JavaScript before the async rewrite
  ORIGINE_REPL_BUF_DIAGNOSTICS = 6   // "file:line:col: error: message" lines
};

// What origine_repl_command found in a line.
enum {
  ORIGINE_REPL_CMD_SOURCE = 0,  // not a command: source
  ORIGINE_REPL_CMD_HELP = 1,
  ORIGINE_REPL_CMD_EXIT = 2,
  ORIGINE_REPL_CMD_CLEAR = 3,
  ORIGINE_REPL_CMD_HISTORY = 4,
  ORIGINE_REPL_CMD_AGAIN = 5,     // *number: one-based history entry, 0 for the latest
  ORIGINE_REPL_CMD_COMPLETE = 6,  // argument in ORIGINE_REPL_BUF_ARGUMENT
  ORIGINE_REPL_CMD_INVALID = 7
};

enum { ORIGINE_REPL_APPEND_OK = 0, ORIGINE_REPL_APPEND_TOO_LONG = 1 };

// Result of origine_repl_prepare.
enum {
  ORIGINE_REPL_PREPARED_SCRIPT = 0,      // run BUF_CODE as a script
  ORIGINE_REPL_PREPARED_ASYNC = 1,       // BUF_CODE is an async function call: await its promise
  ORIGINE_REPL_PREPARED_INCOMPLETE = 2,  // the input stops mid-construct: read another line
  ORIGINE_REPL_PREPARED_ERROR = 3        // wrong input; BUF_DIAGNOSTICS says why
};

// Result of the origine_repl_edit_* calls.
enum {
  ORIGINE_REPL_EDIT_CONTINUE = 0,  // keep reading
  ORIGINE_REPL_EDIT_LINE = 1,      // a line is ready (BUF_LINE)
  ORIGINE_REPL_EDIT_EOF = 2,       // end of input with nothing typed
  ORIGINE_REPL_EDIT_CANCELED = 3   // Ctrl-C
};

// What the host provides to the line editor on each call. Completions come from live objects, so
// they are asked for through a callback.
typedef struct OrigineReplHost {
  void *ctx;
  // Pushes the completion list for prefix (newline separated names, or a notice starting with
  // "(" or "Use ") into sink with origine_repl_sink_push. False when completion failed.
  bool (*complete)(void *ctx, const uint8_t *prefix, size_t prefix_len, OrigineReplSink *sink);
} OrigineReplHost;

uint32_t origine_repl_abi_version(void);
// colors: syntax colors and inline suggestions in the line editor.
OrigineRepl *origine_repl_new(bool colors);
void origine_repl_free(OrigineRepl *repl);
const uint8_t *origine_repl_buffer(const OrigineRepl *repl, uint32_t which, size_t *len);
void origine_repl_sink_push(OrigineReplSink *sink, const uint8_t *bytes, size_t len);

// Input: dot-commands, pending multiline source and bounded history.
uint32_t origine_repl_command(OrigineRepl *repl, const uint8_t *line, size_t len, size_t *number);
uint32_t origine_repl_append(OrigineRepl *repl, const uint8_t *line, size_t len);
void origine_repl_clear(OrigineRepl *repl);
void origine_repl_remember(OrigineRepl *repl);
// Replaces the pending source by a one-based history entry (0 selects the latest). False when
// there is no such entry.
bool origine_repl_recall(OrigineRepl *repl, size_t number);
size_t origine_repl_history_len(const OrigineRepl *repl);
const uint8_t *origine_repl_history_get(const OrigineRepl *repl, size_t index, size_t *len);

// Parses the pending source: erases types, finds unfinished input, rewrites top-level await and
// import. The result is a ORIGINE_REPL_PREPARED_* value; BUF_CODE, BUF_PLAIN and BUF_DIAGNOSTICS
// hold the details.
uint32_t origine_repl_prepare(OrigineRepl *repl);

// Line editor. The host reads bytes from the terminal in raw mode and writes
// ORIGINE_REPL_BUF_OUTPUT back after every call; width is the terminal's columns.
void origine_repl_edit_begin(OrigineRepl *repl, const uint8_t *prompt, size_t len);
uint32_t origine_repl_edit_feed(OrigineRepl *repl, uint8_t byte, uint32_t width, const OrigineReplHost *host);
// A read timed out (see origine_repl_edit_in_sequence).
uint32_t origine_repl_edit_timeout(OrigineRepl *repl, uint32_t width, const OrigineReplHost *host);
uint32_t origine_repl_edit_eof(OrigineRepl *repl);
// True inside an escape sequence: the next read should time out after a few milliseconds.
bool origine_repl_edit_in_sequence(const OrigineRepl *repl);
#endif
