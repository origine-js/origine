// Error classes shared by the glue and origine:@std/errors through the private context bundle.
import { ERRNO } from './errno.js';

const names = new Map([...Object.entries(ERRNO.io), ...Object.entries(ERRNO.host)].map(([name, code]) => [code, name]));

export class OrigineError extends Error {
  constructor(errno, message = '') {
    if (!names.has(errno)) throw new TypeError('errno must be an origine error code');
    if (typeof message !== 'string') throw new TypeError('message must be a string');
    super(message);
    Object.defineProperties(this, {
      errno: { value: errno, enumerable: true },
      name: { value: names.get(errno), enumerable: true },
    });
  }
  static nameOf(code) {
    return names.get(code) ?? 'Unexpected';
  }
  static is(value, code) {
    return (typeof value === 'number' ? value : value?.errno) === code;
  }
  static of(code, message = '') {
    return new this(code, message);
  }
}

export class IoError extends OrigineError {
  static check(fs, value) {
    const code = fs.errno[0];
    if (code !== 0) {
      fs.errno[0] = 0;
      throw of(code);
    }
    return value;
  }
}

export class HostError extends OrigineError {}
export class ImportError extends OrigineError {
  static other(message) {
    if (typeof message !== 'string') throw new IoError(ERRNO.io.InvalidInput, 'ImportError.other: message must be a string');
    return new ImportError(ERRNO.host.Unexpected, message);
  }
}

const constants = (target, source) => {
  for (const [name, value] of Object.entries(source)) Object.defineProperty(target, name, { value, enumerable: true });
  // Keep the existing Error.name(code) helper alongside standard instance names.
  Object.defineProperty(target, 'name', { value: OrigineError.nameOf });
};
constants(IoError, ERRNO.io);
constants(HostError, ERRNO.host);
constants(
  ImportError,
  Object.fromEntries(['NotFound', 'PermissionDenied', 'InvalidInput', 'InvalidData', 'Unsupported'].map(name => [name, ERRNO.io[name]])),
);

const ioCodes = new Set(Object.values(ERRNO.io));
export const of = (code, message = '') => {
  if (!names.has(code)) code = ERRNO.host.Unexpected;
  return new (ioCodes.has(code) ? IoError : HostError)(code, message);
};

for (const C of [OrigineError, IoError, HostError, ImportError]) {
  Object.freeze(C.prototype);
  Object.freeze(C);
}
