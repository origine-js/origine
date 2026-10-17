// `@engine/std/io`: Zig-style Io vocabulary for the init context.
// Pure data: holding any of these values confers no authority. The errno table
// must match `Errno` in api.zig.
const freeze = Object.freeze;

const ERRNO = {
  FileNotFound: 1,
  AccessDenied: 2,
  NotDir: 3,
  IsDir: 4,
  PathAlreadyExists: 5,
  BadHandle: 6,
  StaleHandle: 7,
  InvalidPath: 8,
  NoSpaceLeft: 9,
  Unsupported: 10,
  FileTooBig: 11,
  Unexpected: 255,
};
const NAMES = new Map(Object.entries(ERRNO).map(([name, code]) => [code, name]));

/// Errno values with Zig-style names. `is` accepts a number or any `{ errno }`.
export const IoError = freeze({
  ...ERRNO,
  name: code => NAMES.get(code) ?? 'Unexpected',
  is: (value, code) => (typeof value === 'number' ? value : value?.errno) === code,
  /// Throws a frozen `{ errno, name }` when a sync call left a non-zero errno in
  /// `fs.errno`, and resets the state. Returns `value` otherwise.
  check(fs, value) {
    const code = fs.errno[0];
    if (code === 0) return value;
    fs.errno[0] = 0;
    throw freeze({ errno: code, name: NAMES.get(code) ?? 'Unexpected' });
  },
});

/// Byte limit with `std.Io.Limit` semantics. `unlimited` is Infinity (maxInt(usize)).
export const Limit = freeze({
  unlimited: Infinity,
  nothing: 0,
  limited(n) {
    if (!Number.isSafeInteger(n) || n < 0) throw new RangeError('limit must be a non-negative safe integer');
    return n;
  },
});

const CWD = freeze({ kind: 'dir', fs: 0, id: 0 });

/// Descriptors name something inside one fs object; `cwd()` is the sentinel each
/// fs resolves to its own root.
export const Dir = freeze({
  cwd: () => CWD,
  at: (fs, id) => freeze({ kind: 'dir', fs, id }),
});

export const File = freeze({
  at: (fs, id) => freeze({ kind: 'file', fs, id }),
});

export const FileKind = freeze({ file: 1, directory: 2, sym_link: 3, other: 4 });
