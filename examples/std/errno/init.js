// Run: zig build run -- examples/std/errno/init.js   (or: zig-out/bin/origine examples/std/errno/init.js)
// The error codes as a table. Look codes up by name: the numbers are stable but not meant to be typed. io codes are
// Rust's std::io::ErrorKind names; host codes are origine's own runtime concepts.
//
// Prints (stderr):
//   io NotFound: 10 ; host BadHandle: 2
//   names of io codes are Rust's: TimedOut, PermissionDenied
//   IoError.name(code) and HostError.name(code) agree with the table: true
import { ERRNO } from 'origine:@std/errno';
import { IoError, HostError } from 'origine:@std/errors';
import { eprintln } from 'origine:@std/debug';

export function main() {
  eprintln(`io NotFound: ${ERRNO.io.NotFound} ; host BadHandle: ${ERRNO.host.BadHandle}`);
  eprintln('names of io codes are Rust\'s:', IoError.name(ERRNO.io.TimedOut), IoError.name(ERRNO.io.PermissionDenied));
  eprintln('IoError.name(code) and HostError.name(code) agree with the table:', IoError.name(ERRNO.io.NotFound) === 'NotFound' && HostError.name(ERRNO.host.BadHandle) === 'BadHandle');
}
