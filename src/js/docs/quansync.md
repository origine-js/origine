# `origine:@std/quansync`

Source: [std/quansync.js](../std/quansync.js). Write an operation once; run it synchronously or
asynchronously. After [quansync](https://github.com/quansync-dev/quansync), with one
difference: a function is **indexable by mode name**, so a caller that knows its mode
(from `io.kind`) dispatches without branching.

```js
import { quansync } from 'origine:@std/quansync';

// leaf: two hand-written implementations
const stat = quansync({ sync: (io, p) => io.statSync(p), async: (io, p) => io.stat(p) });
stat[io.kind](io, path);          // io.kind is 'sync' | 'async'

// composite: yield* other quansync calls
const size = quansync(function* (io, p) {
  return (yield* stat(io, p)).size;
}, { sync: (io, p) => stat.sync(io, p).size });   // optional fast paths
```

## Every quansync function `f`

| Form | Meaning |
| --- | --- |
| `f.sync(...args)` | Runs synchronously; returns the result or throws. |
| `f.async(...args)` | Runs asynchronously; returns a promise. |
| `f(...args)` | A **task**: usable with `yield*` / `yield` inside a composite, and awaitable (`await f(...)` runs it asynchronously). Single use. |
| `f[mode]` | `f.sync` or `f.async` for `mode` `'sync'`/`'async'`. |

## Exports

- `quansync(definition, overrides?)`: `definition` is `{ sync, async }` (leaf) or a generator
  function (composite, with optional `{ sync, async }` overrides). Anything else throws `TypeError`.
- `quansync.run(mode, task)` / `run`: run a task in a mode.
- `quansync.isTask(value)`, `quansync.MODES` (`['sync', 'async']`).

## Cost

A leaf's `.sync` and `.async` *are* the given implementations: no wrapper, no allocation.
A composite costs one generator per call, so hot composites should supply a `{ sync }`
fast path (`dirReadFile` in [std/io.js](../std/io.js) does). Inside a generator you may only
`yield` a leaf effect or another task; anything else throws `TypeError`.
