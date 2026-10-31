// Error classes shared by the glue and origine:@std/errors through the private context bundle.
import { ERRNO } from './errno.js';

const names = new Map([...Object.entries(ERRNO.io), ...Object.entries(ERRNO.host)].map(([name, code]) => [code, name]));

const transientCodes = new Set(
  ['WouldBlock', 'TimedOut', 'ResourceBusy', 'ConnectionRefused', 'ConnectionReset', 'TooManyOpenFiles'].map(name => ERRNO.io[name]),
);

export class OrigineError extends Error {
  constructor(errno, message = '', name = names.get(errno)) {
    if (!names.has(errno)) throw new TypeError('errno must be an origine error code');
    if (typeof message !== 'string') throw new TypeError('message must be a string');
    super(message);
    Object.defineProperties(this, {
      errno: { value: errno, enumerable: true },
      name: { value: name, enumerable: true },
    });
  }
  static nameOf(code) {
    return names.get(code) ?? 'Unexpected';
  }
  static is(value, code) {
    return (typeof value === 'number' ? value : value?.errno) === code;
  }
  // Whether the condition behind `value` (an error or an errno) may pass by itself: the same request can succeed
  // later. A hint, not a promise that repeating the request is safe: that depends on the operation.
  static transient(value) {
    return transientCodes.has(typeof value === 'number' ? value : value?.errno);
  }
  static of(code, message = '') {
    return new this(code, message);
  }
}

// The `ErrorDetail` of the scope a sync grant belongs to. Kept here, not on the grant: the grant is guest-visible.
const grantDetails = new WeakMap();
export const bindDetail = (grant, detail) => {
  grantDetails.set(grant, detail);
  return grant;
};

export class IoError extends OrigineError {
  static check(fs, value) {
    const code = fs.errno[0];
    if (code !== 0) {
      fs.errno[0] = 0;
      const detail = grantDetails.get(fs);
      const error = fromDetail(code, detail);
      resetDetail(detail);
      throw error;
    }
    return value;
  }
}

export class HostError extends OrigineError {}
// An import, an evaluated source or a preload that failed. `errno` is the kind of the cause (a hook's
// `ImportHook.reject(ImportError.PermissionDenied)`, else `Unexpected`), `subject` the module it was for and
// `referrer` the module that imported it (when it was a static import), and `cause` an error rebuilt in this realm from what the child reported: nothing of the child's objects crosses.
export class ModuleError extends OrigineError {
  constructor(errno, message = '', subject = undefined, cause = undefined, referrer = undefined) {
    super(errno, message, 'ModuleError');
    if (subject !== undefined) Object.defineProperty(this, 'subject', { value: subject, enumerable: true });
    if (referrer !== undefined) Object.defineProperty(this, 'referrer', { value: referrer, enumerable: true });
    if (cause !== undefined) Object.defineProperty(this, 'cause', { value: cause, configurable: true, writable: true });
  }
}
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

// The `ErrorDetail` object (src/api/error_detail.zig, rust `error_value`): fields always present,
// `undefined` when unset. Its fields become own properties of the error, `subject` is its message.
export const resetDetail = detail => {
  if (detail === undefined) return;
  detail.subject = undefined;
  detail.os = undefined;
};
export const fromDetail = (code, detail) => {
  const subject = typeof detail?.subject === 'string' ? detail.subject : undefined;
  const os = typeof detail?.os === 'number' ? detail.os : undefined;
  const error = of(code, subject ?? '');
  if (subject !== undefined) Object.defineProperty(error, 'subject', { value: subject, enumerable: true });
  if (os !== undefined) Object.defineProperty(error, 'os', { value: os, enumerable: true });
  return error;
};

// The rejection a failed import carries (src/api/context.zig `failureValue`: `errno`, `name`, `message`,
// `subject`) as the `ModuleError` callers get. A known cause kind is its own explanation; an unknown one keeps the
// child's text.
export const moduleFailure = e => {
  if (e?.name !== 'ModuleError' || typeof e.errno !== 'number' || !names.has(e.errno)) return e;
  const subject = typeof e.subject === 'string' ? e.subject : undefined;
  const text = typeof e.message === 'string' ? e.message : '';
  const known = e.errno !== ERRNO.host.Unexpected;
  const cause = known ? of(e.errno) : new Error(text);
  const reason = known ? names.get(e.errno) : text;
  const message = subject === undefined ? reason : `${subject}: ${reason}`;
  const referrer = typeof e.referrer === 'string' ? e.referrer : undefined;
  return new ModuleError(e.errno, message, subject, cause, referrer);
};

for (const C of [OrigineError, IoError, HostError, ImportError, ModuleError]) {
  Object.freeze(C.prototype);
  Object.freeze(C);
}
