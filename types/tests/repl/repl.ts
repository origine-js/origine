// In the REPL `api` is a global: opt in with "@origine/types/repl".
import "@origine/types/repl";
import { eprintln } from "origine:@std/debug";

const sync = api.fs.requestSync({ access: "r" });
eprintln(sync.kind);
