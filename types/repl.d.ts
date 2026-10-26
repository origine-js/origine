// Opt-in declarations for code typed against the REPL. In the REPL the `api` that `main(api)` would
// receive is also a global. Add it with `"types": ["@origine/types", "@origine/types/repl"]`.
import type { Api } from "./api.d.ts";

declare global {
  /** The host API, installed as a read-only global by the REPL only. Programs get it from `main(api)`. */
  const api: Api;
}

export {};
