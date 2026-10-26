// In the REPL `api` is a global: opt in with "@origine/types/repl".
import "@origine/types/repl";

const sync = api.fs.requestSync({ access: "r" });
print(sync.kind);
