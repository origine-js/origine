# API guidelines

For anyone (agent or human) adding or changing a public name: JS `api.*`, `origine:@std/*`, native tables, options, errors. The goal is an API with no **footgun**: a name, return value, option or default that makes the obvious call do something else.

**Done** means every public name, option, return value and default you touched passes the three tests below, and the checklist at the end is answered line by line.

## Natural

A call returns what its name makes the caller expect.

- A `write`/`send`/`put` returns the **number of bytes** taken, or a promise that settles when they are out. A `read` returns the data or a count. A `find` returns the thing or `undefined`.
- A `boolean` answers a question and is named like one (`closed`, `paused`). A boolean *status* of an action ("did it all fit?", "may I continue?") is a footgun: return the integer and let the caller compare, or expose state as a getter (`queued.bytes`).
- A signal the caller must wait for is a promise or an event, never a return value to be remembered (`queued.drained()`, the `drain` event).
- Units are in the name or the type: bytes are integers, milliseconds are `ms`, deadlines say what clock.
- Errors carry one meaning each. Bad argument, denied, absent and broken are four different errors (Rust `io::ErrorKind` is the vocabulary). A code that means "something about the path or arguments" is a footgun.
- A function with the name of a standard one behaves like the standard one (`metadata` follows symlinks like Rust's, `decodeUtf8` replaces like `TextDecoder`). When it cannot, pick another name.

## Explicit

Everything that costs something or makes a choice is visible at the call site.

- **Explicit beats implicit** (Zen of Python). A buffer, copy, allocation, detach, block or retained reference the caller did not ask for is a footgun. Name it (`writeMove` transfers the buffer; `write` copies and never detaches) or make the caller pass it.
- A default is fine when every user would pick it and it hides no cost. A choice with consequences is a **required option** with no default: `mode: 'event' | 'pull'`, `access: 'r' | 'w' | 'rw'`.
- Degrade loudly. A request the grant cannot honour fails (`AccessDenied`); it never returns a weaker object. Unsupported input is `Unsupported`, never a silent fallback to a slower or different path.
- Modes are types. Two behaviours that cannot be mixed are two handle types (`Socket<'event'>`, `Socket<'pull'>`) with an explicit, consuming transfer between them, not one object with methods that race.
- Limits and capacities are numbers the caller can read and set (`queued.limit`), not constants in the implementation.
- Lifetime is visible: what keeps the program alive, what `close()` discards, who owns a buffer after the call.

## One obvious way

One operation has one name and one shape (Zen of Python).

- No aliases, no overload that does the same thing with another argument form, no promise and callback twins of one function.
- A second shape earns its place only when its semantics differ in one sentence you can write in the docs (`direct.write`: unbuffered, may take less, never queues; `queued.send`: whole payload, resolves when out). If the sentence is "same, but convenient", delete it.
- Lanes that must cooperate state who has priority (`queued` before `direct`).
- Removing is cheaper now than deprecating later. Prefer deleting the weaker shape in the same change that adds the better one.

## Naming

Short names. The path already says most of it.

- Options: the **noun or state**, nested by meaning, not a verb phrase.

  | Not | Write |
  | --- | --- |
  | `allowWrite`, `canWrite`, `writable: true` | `write`, or `access: 'w'` |
  | `allowFoo` / `enableFoo` | `foo`, `features.foo` |
  | `enableOrigineNamespace` | `origineNamespace`, `namespace.origine` |
  | `allowHalfOpen` | no option: the call says it, `end('write')` |
  | `useSandbox`, `withCache` | `sandbox`, `cache` |
  | `sendQueueLimit` on a socket | `queued.limit` |

- Drop the general verbs `allow`, `enable`, `is`, `has`, `use`, `with`, `should`, `get`, `set` when the option path or the property name already carries the meaning. Keep a verb when it is the operation (`close`, `send`, `pause`).
- A boolean option is named after what is on, not after permission to turn it on.
- Methods are `verb` or `verb` + one object; getters are nouns. No stutter: `socket.queued.bytes`, not `socket.socketQueueBytes`.
- One word when one word is exact, two at most. If a name needs three words, the thing wants a namespace (`queued.*`, `direct.*`) or is two things.
- Reuse the host vocabulary: Rust names for fs and errors, Zig names for `std.Io` ops, WHATWG names for text. A reader who knows the original should guess the name.
- Same concept, same word everywhere (`limit`, not `limit` here and `max`/`cap` there).

## Checklist

Answer for each public name, option, return value and default in the change:

1. What does a caller who has only read the name expect it to return and do? Is that what happens?
2. Does anything allocate, copy, detach, block, retain or degrade without the call site saying so?
3. Is there another way to do the same thing in this API? Which one survives?
4. Does the name shed every word that its path or type already says?
5. Which error does each failure produce, and does that error mean one thing?

Document the answer to question 2 in the API's doc next to the name, in the same change.
