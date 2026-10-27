# `origine:@std/debug`

Source: [std/debug.js](../std/debug.js), native [std/debug.zig](../../api/std/debug.zig). A debugging
hook of the host and the only output a program has without a capability. V8's `console` is not
connected to the terminal.

```js
import { eprintln } from 'origine:@std/debug';
```

| Export | Behavior |
| --- | --- |
| `eprintln(...values)` | Converts each value with `String()`, joins them with a space and writes one line to the process's standard error. It never throws and reports no write error. |

Cost (checklist 2): the line is built as a JS string, copied once into the call arena and written with
libc `write` through a 512-byte stack buffer (longer lines take several `write` calls). Nothing is
retained, and there is no global: a child scope needs `origineNamespace: true` to import it.
