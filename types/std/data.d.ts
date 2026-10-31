// `origine:@std/data`: hand data to another realm without sharing the realm. Two separate calls, applied to
// any object; nothing in the graph API copies or freezes on a caller's behalf.
declare module "origine:@std/data" {
  /** Options of {@link snapshot}. */
  export interface SnapshotOptions {
    /** Also deeply freeze the copy (`deepFreeze`). Default `false`. */
    readonly deepFreeze?: boolean;
  }

  /**
   * Freezes `value` and everything it reaches **in place** and returns it: own data properties and the prototype
   * chain and a class's statics, so freezing an exported class also freezes the prototypes involved. It is
   * `Object.freeze`, transitively, which is why it is not called `freeze`. It is not a security boundary by itself:
   * a frozen function still has `fn.constructor`; string-to-code is closed by `security.codeGeneration`. A primitive is returned as it is. A `Map`, a `Set`, a typed array, an `ArrayBuffer`, a
   * promise or a `Proxy` anywhere in the graph is `Unsupported` (the graph may be partly frozen by then). An
   * accessor property is frozen as a property, but its getter still runs and may return anything. Freezing something its owner still writes to makes the owner's own writes fail: that is the
   * caller's responsibility.
   */
  export function deepFreeze<T>(value: T): T;

  /**
   * A copy of plain data, made in this realm: primitives, arrays and objects whose prototype is a realm's
   * `Object.prototype` or null, with cycles and shared references kept. The source is not touched. With
   * `deepFreeze: true` the copy is also deeply frozen. A function or class, an accessor property, a `Map`, a
   * `Set`, a typed array, a promise, a `Proxy`, a `Date` or any object with another prototype is `Unsupported`,
   * naming where it is: nothing is shared silently, since a shared object would leak its realm.
   * Symbol-keyed properties are skipped.
   */
  export function snapshot<T>(value: T, options?: SnapshotOptions): T;
}
