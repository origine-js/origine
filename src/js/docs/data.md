# origine:@std/data

Source: [std/data.js](../std/data.js). Types: `types/std/data.d.ts`. Importable only from the **init context**.

Hand data to another realm without sharing the realm. The graph API never copies or freezes on a caller's behalf
(`graph.exports(ref)` is the live namespace, `Import.link(ref)` is the module itself); these are the two separate
calls that do, applied to any object.

```js
import { snapshot, deepFreeze } from 'origine:@std/data';
import { Import } from 'origine:@std/graph/import';

const ns = api.graph.exports(ref);                       // live: the context's own objects
const data = snapshot(ns.config, { freeze: true });      // a frozen copy in this realm
hooks: [r => (r.id === 'cfg:app' ? Import.exports({ config: data }) : Import.next())]
```

| Call | Returns | Cost |
|---|---|---|
| `snapshot(value, { freeze? })` | a copy of plain data in this realm (primitives, arrays, objects whose prototype is a realm's `Object.prototype` or null; cycles and shared references kept); `freeze: true` also deep-freezes the copy; absent `freeze` means `false` | allocates the copy; walks the whole graph |
| `deepFreeze(value)` | `value` itself, now frozen with everything it reaches (own data properties and the prototype chain) | changes the object in place: its owner's own writes fail afterwards, which is the caller's responsibility |

`snapshot` refuses what it cannot copy with `Unsupported` naming the path (`$.a.0.b`): a function or class, an accessor, a `Map`,
a `Set`, a typed array, a promise, a `Proxy`, a `Date` and any object with another prototype. Nothing is shared silently, because a shared object would leak its
realm. `deepFreeze` refuses a `Map`, a `Set`, a typed array, an `ArrayBuffer`, a promise and a `Proxy` with `Unsupported` (the graph may be partly frozen by then); an accessor property is frozen as a property but its getter still runs.
A bad `options` is `InvalidInput`. The name is `deepFreeze`, not `seal` or `freeze`: `Object.seal` only stops adding and removing, and `Object.freeze` is shallow.
