# REPL architecture: what is Rust, what is Zig

The REPL is split along one line: **everything that is a pure function of text and key presses is
Rust; everything that touches V8, the platform loop or the terminal device is Zig** (plus one JS
file that has to run inside V8). The Rust side never calls the operating system and never holds a
V8 handle, so it is tested without a terminal or an engine, and it runs under Miri.

```
 terminal bytes ──► tty.zig ──byte──► ┌────────────────────────── origine_repl (Rust) ──────────────────────┐
   (raw mode,        │  ▲            │ keys ─► editor ─► edit / render / complete        (line editor)    │
    poll, ioctl)     │  └─ output ◄──│ command, input (pending source, history)                           │
                     │               │ analyze ─► rewrite              (oxc parser, types erased)          │
                     │               └──────────────▲───────────────────────────────┬──────────────────────┘
                     │   completion callback        │ origine_repl.h (surface G)    │ code / plain / diagnostics
                     ▼   (live objects)             │                               ▼
              helpers.zig ◄──── session.zig (loop, dot-command effects, evaluate, settle promises) ──► V8
                  │                  │
            helpers.js (inspect,     └─ eval.zig, display.zig
            complete, track)
```

## Rust: `rust/crates/origine_repl`

| module | owns | why Rust |
|---|---|---|
| `command` | `.help`, `.again 2`, `.complete x` parsing | pure text; exhaustive `match` instead of string chains |
| `input` | pending multiline source, 64 KiB bound, 100-entry history, recall | plain state with invariants; `String` keeps it valid UTF-8 |
| `complete` | completion context (`foo().` vs `foo.`), "am I inside a string / template / comment", ghost suggestion, common prefix | text scanning (a port of Bun's REPL, see `BUN-NOTICE.md`); never splits a UTF-8 character |
| `keys` | terminal bytes to key presses, escape sequences, UTF-8 decoding | an incremental state machine; invalid sequences are rejected by `std::str` instead of by hand |
| `edit` | the line: cursor, word motions, kill/yank, transpose, case, undo | pure functions of line and cursor, unit-tested |
| `editor` | readline behaviour: history browsing, Ctrl-R search, Tab completion, suggestions, viewport redraw | the whole state machine; it only produces output bytes |
| `render` | control-character masking, syntax colors of the line, cell widths (`unicode-width`) | text in, text out; wide and zero-width characters are handled correctly |
| `analyze` | one entry to runnable code: object-literal retry for a leading `{`, types erased, sloppy-script fallback, "unfinished input" | needs the **parser**, and the parser is Rust (oxc) |
| `rewrite` | top-level `await` / static `import` to an async function, declarations to globals | works on the AST, not on guesses about the text |
| `lib` | the C ABI, panic guards, the compile-time contract checks | |

`analyze` is the heart of it. For one entry it decides, with one parse of the text as a module:

1. a leading `{` is tried as `({ ... })` first (an object literal), otherwise as a block;
2. the entry parses: types are erased (`origine_oxc::erase_types`, keeping imports), then
   `rewrite` runs when there is a top-level `await` or `import`; the result is **Ready**;
3. the entry does not parse as a module but parses as a *script* (`with`, legacy octal ...):
   it runs as written, **Ready**;
4. neither parses and the first error is at the end of the input (or an unterminated comment or
   template): **Incomplete**, the REPL reads another line;
5. otherwise **Error** with `repl.ts:line:col: error: message`.

The old design asked V8 "does this compile?" several times per line and combined three
independent heuristics (V8's message text, a regex tokenizer in `helpers.js`, a `callsAwait`
substring search). There is now one answer from one parser, and V8 only ever runs code that has
already been accepted.

Without the `typescript` feature (`zig build -Dtypescript=false`) the same pipeline parses plain
JavaScript and skips the erase step; the editor, parsing and rewrite work in both builds.

## Zig: `src/repl`

| file | owns | why Zig |
|---|---|---|
| `tty.zig` | raw mode (`tcsetattr`), `poll`/`read` of one byte, `write`, terminal width (`ioctl`), the completion callback | the device and the syscalls; this is the only place that knows there is a terminal. 80 lines, no decisions |
| `engine.zig` | the Zig view of the C ABI (`Engine`) | an adapter: slices instead of pointer+length, enums instead of integers |
| `session.zig` | the read-eval-print loop; what each dot-command *does* (print help, list history, run `.again`); evaluate; settle async results; install `api` | it drives the runtime and the platform, which are Zig |
| `eval.zig` | `scope.eval` under the REPL's script name | V8 |
| `helpers.zig` + `helpers.js` | `inspect`, `complete`, `track`, `_` / `_error` | they read **live objects** (descriptors, prototypes, promise state) without running guest code. That needs V8 handles and a private adapter, so it cannot move out of V8 |
| `display.zig` | printing values and errors | V8 `toString` under a `TryCatch` |

### The boundary

The Rust crate gets *text and key bytes*, and answers with *text and small integers*. Three rules
keep it that way:

1. **No handle crosses.** Strings are copied or borrowed for one call; returned buffers
   (`origine_repl_buffer`) belong to the `OrigineRepl` and are valid until its next call.
2. **The editor asks, the host answers.** Completions depend on live objects, so the editor calls
   `OrigineReplHost.complete(prefix, sink)` during a key press. The Zig callback forwards to
   `helpers.js` and pushes the text back. Nothing else needs V8.
3. **The editor produces bytes, the host writes them.** After every call `BUF_OUTPUT` holds the
   escape sequences to send. A paused read is reported with `origine_repl_edit_timeout`
   (that is how a lone Escape is told from the start of an arrow key); the terminal width is an
   argument of every call.

Nothing in the ABI can fail by unwinding: each entry that runs non-trivial code (`prepare`, the
editor) is behind `catch_unwind` and reports a failed result instead.

### The evaluation flow

```
line ─► engine.command(line)          source? ─► engine.append(line) ─► engine.prepare()
                                                      │
        incomplete ◄──────────────────────────────────┤  (read another line)
        error      ─► print diagnostics               │
        script     ─► scope.eval(BUF_CODE)            │
        async      ─► scope.eval(BUF_CODE) = promise ─► settle (pump loop until it resolves)
                                                      ▼
                       helpers.remember(BUF_PLAIN, result)    ← the JavaScript *before* the rewrite
                       helpers.display(result)
```

`BUF_PLAIN` matters: completion tracks which names an input declared, and it must see
`const x = ...`, not the generated `x = ...` assignment inside the async wrapper.

## Why the line is drawn here

* **Rust is better at the parts that were hand-rolled in Zig and JS:** text and byte parsing with
  `str`/`char` and exhaustive matching, a real parser instead of regular expressions, Unicode
  width tables, tests that run under Miri.
* **Zig stays where the code is the glue:** the V8 bindings, the runtime and platform, process
  and device I/O. `origine_api` (the V8 glue in Rust) exists, but the REPL session needs the
  *managed* runtime's scope and promise settling, which are Zig types; moving the loop to Rust
  would only add a second binding layer.
* **JavaScript stays for inspection.** `helpers.js` formats and completes by looking at the
  engine's own objects. The line editor's colors used to be produced there too; they are now
  produced in Rust (`render::highlight`), and only the colors of *inspected values* remain in JS.

## Testing

| layer | where |
|---|---|
| parsing, rewrite, editor, keys, ABI round trips | `cargo test -p origine_repl` (also `--features typescript`), Miri via `just check-rust` |
| the ABI and the Zig adapter | `src/tests/managed/repl.zig` (engine, pending input, TypeScript, await rewrite run in V8) |
| the whole thing in a pseudo-terminal | `just test-repl` (`src/repl/tests/terminal_smoke.py`) |
| header, Zig and Rust declarations agree | `just check-contracts` (surface G in [contracts.md](contracts.md)) |
