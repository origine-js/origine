import { OrigineError, IoError, HostError, ImportError } from "origine:@std/errors";
import { ImportResolver } from "origine:@std/graph/resolve";
import { relative } from "origine:@std/graph/resolve/layers";
import type { DirHandle } from "../fs.d.ts";

const io: OrigineError = new IoError(IoError.NotFound, "missing");
const host: Error = new HostError(HostError.BadHandle);
const failure: Error = ImportError.other("failed");
const imported: OrigineError = new ImportError(ImportError.Unsupported);
void [io.message, io.stack, host, failure, imported];

ImportResolver.layered().layer(relative());
// @ts-expect-error Private descriptor identity cannot be supplied by an object literal.
ImportResolver.layered().layer({ host: "relative", kind: "layer" });
// @ts-expect-error A filesystem reference must come from its factory.
const fake: DirHandle = { kind: "dir", fs: 0, id: 0 };
void fake;
