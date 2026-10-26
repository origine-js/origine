// Globals of the hardened context. There is no DOM, `TextEncoder`/`TextDecoder`, `fetch`,
// `setTimeout`, `queueMicrotask`, `structuredClone` or `WebAssembly`; use `origine:@std/text`,
// `api.net`, `api.io` timers and promises instead.

/**
 * Writes its arguments, converted with `String()` and separated by spaces, as one line to the
 * process's standard error.
 *
 * It is a debugging hook of the host (the engine's source marks it as temporary), the only
 * output a program has without a capability. V8's own `console` object exists in the context but
 * is not connected to the terminal, so it is not declared here.
 */
declare function print(...values: unknown[]): void;
