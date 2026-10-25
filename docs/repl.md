# JavaScript REPL

Run `origine` without a file argument. The interactive prompt is `> `; incomplete
JavaScript uses `... ` until the expression, function, template, or block comment
is complete. V8 checks the syntax without running it, so multiline input executes
once. Actual syntax errors are reported immediately. EOF with incomplete input
reports its syntax error before exiting.

```js
> const add = (a, b) => {
...   return a + b;
... }
undefined
> { result: add(20, 22), values: [1, 2] }
{ result: 42, values: [ 1, 2 ] }
```

Declarations persist for the session. Object results show their enumerable own
properties, with quoted strings, arrays, function labels, and circular references.
Inspection skips getters and proxies. Output is limited to three levels, twenty
properties per object, one hundred expanded objects, and 256 characters per string.
Small objects and arrays stay on one line; longer collections wrap at 80 columns
with two-space indentation, including nested values. Piped output uses the same
formatting without terminal escape sequences.
Bare object literals evaluate as expressions, including `{a:123,b:234}` and
multiline objects. Syntax probing chooses the expression or statement grammar
before execution; a throwing expression is never retried as a statement.
Maps and Sets show their entries, typed arrays show their type and contents, and
regular expressions and Errors have dedicated displays. Colored input and output
are enabled on interactive terminals; `NO_COLOR` disables colors. Getters, proxies,
and custom inspect hooks are not invoked. `_` holds the last result, and `_error`
holds the last thrown value. Inspection is a display view, not serialization.

| Command | Behavior |
| --- | --- |
| `.help` | Show available commands. |
| `.exit` | Exit; `exit()` and Ctrl+D also exit. |
| `.clear` or `.break` | Discard the pending multiline input. |
| `.history` | List up to 100 evaluated inputs, numbered from 1. |
| `.again [number]` | Evaluate that history entry; omit the number for the latest. |
| `.complete [prefix]` | List matching global/property names, e.g. `.complete Math.ma`. |

History is kept in memory for the current session, including failed evaluations.
Consecutive duplicates share an entry; command lines themselves are not recorded.
Numbers refer to the currently displayed history. Clear pending multiline input
before recalling history. Input is limited to 64 KiB per evaluation.

Press **Tab** to complete the global name or dotted property path at the cursor.
As in Bun's native REPL, a dim inline suggestion shows the shortest matching name
while typing at the end of a line. **Tab**, **Right**, or **End** accepts it;
**Enter** executes only the text you typed. Without an inline suggestion, Tab
inserts a unique match or expands a shared prefix, then lists candidates when no
further expansion is possible. Dot commands such as `.he` also complete.
For example, `Math.ma` followed by Tab becomes `Math.max`. Tab after whitespace
inserts two spaces for indentation. `.complete` remains available in piped input.
Both forms follow data properties without invoking getters or proxy traps and
show at most 100 matches. REPL lexical bindings (`let`, `const`, and classes) are
tracked through a private identifier-only V8 lookup; guest `eval` stays disabled.
Completion is suppressed inside strings, template text, and comments, including
strings opened on an earlier line. Mid-identifier Tab does not duplicate an
existing suffix.

The interactive editor supports Left/Right, Home/End (also Ctrl+A/Ctrl+E),
Backspace/Delete, Ctrl+K to clear after the cursor, and Ctrl+U to clear before it.
Up/Down (also Ctrl+P/Ctrl+N) navigate history and restore the draft when moving
past the newest entry. Ctrl+B/Ctrl+F move backward/forward by a character.
Long lines scroll horizontally. Ctrl+C discards the current input and any pending
multiline input; Ctrl+D on an empty line exits. Terminal settings are restored
before evaluation and on EOF or input errors.

Piped input works with the same multiline and command handling, without banners or
prompts. File execution (`origine path/to/init.js`) continues to use the init-module
entry point and is independent of REPL behavior.

Completion context parsing, inline suggestions, and acceptance/history behavior
are ported from [Bun's native REPL](https://github.com/oven-sh/bun/blob/5c6d4e24cd185d5bef8d98e7f1f1e3ef10ac163f/src/runtime/cli/repl.rs).
See [the source attribution and license](../src/repl/BUN-NOTICE.md). V8 evaluation,
the value inspector, and the lexical lookup adapter remain Origine implementations.

Run `just test-repl` for the pseudo-terminal regressions, including the exact bare
object input, suggestion acceptance, history, colors, and terminal restoration.
