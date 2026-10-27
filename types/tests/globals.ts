// Programs import `eprintln` (there is no global print hook) and do not have the REPL's global `api`.
import { eprintln } from "origine:@std/debug";

eprintln("hello", 1, { a: 1 });

// @ts-expect-error `api` is a global only in the REPL ("@origine/types/repl"); programs get it from main(api)
api.fs;
