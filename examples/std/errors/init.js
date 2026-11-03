// Run: zig build run -- examples/std/errors/init.js   (or: zig-out/bin/origine examples/std/errors/init.js)
// Every failure origine raises is an OrigineError subclass with an errno, a name, a message and a stack: IoError for
// file and socket failures, HostError for runtime ones (a bad handle, a canceled operation), ImportError for hooks.
// Narrow with the static is(value, code). A caught value is unknown: it can be any thrown thing.
//
// Prints (stderr):
//   IoError.of(NotFound): IoError NotFound, errno 10, instanceof OrigineError: true
//   HostError.is(BadHandle error, HostError.BadHandle): true
//   OrigineError.transient(WouldBlock): true ; transient(NotFound): false
//   ImportError.is(PermissionDenied code): true
import { OrigineError, IoError, HostError, ImportError } from 'origine:@std/errors';
import { ERRNO } from 'origine:@std/errno';
import { eprintln } from 'origine:@std/debug';

export function main() {
  const notFound = IoError.of(ERRNO.io.NotFound, 'missing.txt');
  eprintln(`IoError.of(NotFound): ${notFound.name}, errno ${notFound.errno}, instanceof OrigineError: ${notFound instanceof OrigineError}`);

  const badHandle = HostError.of(ERRNO.host.BadHandle);
  eprintln('HostError.is(BadHandle error, HostError.BadHandle):', HostError.is(badHandle, ERRNO.host.BadHandle));

  eprintln(`OrigineError.transient(WouldBlock): ${OrigineError.transient(ERRNO.io.WouldBlock)} ; transient(NotFound): ${OrigineError.transient(ERRNO.io.NotFound)}`);

  eprintln('ImportError.is(PermissionDenied code):', ImportError.is(ImportError.PermissionDenied, ImportError.PermissionDenied));
}
